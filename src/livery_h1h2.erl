-module(livery_h1h2).
-moduledoc """
One TLS listener serving HTTP/2 and HTTP/1.1, chosen per connection
by ALPN.

Livery owns the listen socket here rather than delegating it to `h1`
or `h2`, because only the process that ran the handshake knows which
protocol the client asked for. Per connection the listener:

1. Accepts, then hands the socket to a fresh process, so a stalled
   handshake never blocks the accept queue.
2. Runs `ssl:handshake/2` and reads `ssl:negotiated_protocol/1`.
3. Calls `h2:serve_socket/2` for `h2`, and `h1:serve_socket/2` for
   `http/1.1` and for a client that offered no ALPN at all.
4. Stays alive for the connection's lifetime: `serve_socket/2` links
   the connection to its caller, so the process that dispatched is
   the one the connection dies with.

Requests dispatch through `livery_h1` and `livery_h2` exactly as on
the dedicated listeners, so handlers, middleware, and
`livery_req:protocol/1` see the real per-connection protocol. The
negotiated ALPN travels on the stream and comes back out of
`Adapter:peer_info/1`.

The server prefers the protocols in the order `alpn` lists them, so
the default `[h2, http1]` means h2 wins whenever a client offers
both.
""".

-behaviour(gen_server).

-export([start/1, start/3, stop/1, stop_accepting/1, server_port/1]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export_type([listen_opts/0, listener/0, protocol/0]).

-define(DEFAULT_HANDSHAKE_TIMEOUT, 30000).
-define(H2, <<"h2">>).
-define(HTTP1, <<"http/1.1">>).

-type listener() :: {pid(), inet:port_number()}.
-type protocol() :: h2 | http1.

-type listen_opts() :: #{
    port => inet:port_number(),
    %% Bind address. An IPv6 8-tuple selects the inet6 family.
    ip => inet:ip_address(),
    %% Bind the IPv6 wildcard (`::') when no explicit `ip' is given.
    inet6 => boolean(),
    %% Required in practice: without both, `start/1' returns
    %% `{error, {missing_required_option, [cert, key]}}'.
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    verify => verify_none | verify_peer,
    ssl_opts => [ssl:tls_server_option()],
    %% Protocols to advertise, most preferred first. Defaults to
    %% `[h2, http1]'.
    alpn => [protocol()],
    acceptors => pos_integer(),
    handshake_timeout => timeout(),
    stack := livery_middleware:stack(),
    handler := livery_middleware:handler(),
    %% The rest of the map is forwarded whole to the adapter that ends
    %% up serving each connection, so `livery_h1:listen_opts()' and
    %% `livery_h2:listen_opts()' are the full lists of what else is
    %% understood here (`max_body', h1's parser size limits, h2's
    %% `settings', ...).
    atom() => term()
}.

-record(state, {
    listen :: ssl:sslsocket() | undefined,
    port :: inet:port_number(),
    acceptors = [] :: [pid()],
    conns = #{} :: #{pid() => true},
    conn_args :: conn_args()
}).

-type state() :: #state{}.
-type conn_args() :: #{
    handshake_timeout := timeout(),
    h2 := map(),
    http1 := map(),
    no_alpn := map()
}.

%%====================================================================
%% Public API
%%====================================================================

-doc """
Start a multiplexed TLS listener.

`Opts` must include `cert`, `key`, `stack`, and `handler`. `port`
defaults to 0 (random port). Returns a handle for `stop/1`,
`stop_accepting/1`, and `server_port/1`.
""".
-spec start(listen_opts()) -> {ok, listener()} | {error, term()}.
start(Opts) when is_map(Opts) ->
    start(undefined, Opts, #{}).

-spec start(atom() | undefined, listen_opts(), map()) ->
    {ok, listener()} | {error, term()}.
start(_Name, Opts, _StartOpts) ->
    case gen_server:start(?MODULE, Opts, []) of
        {ok, Pid} -> {ok, {Pid, gen_server:call(Pid, port)}};
        {error, _} = Error -> Error
    end.

-doc """
Stop the listener. Synchronous: closes the listen socket and every
accepted connection before returning.
""".
-spec stop(listener()) -> ok.
stop({Pid, _Port}) ->
    try
        gen_server:stop(Pid)
    catch
        exit:_ -> ok
    end.

-doc """
Stop accepting new connections while continuing to serve the
established ones. Call `stop/1` afterwards to close them.
""".
-spec stop_accepting(listener()) -> ok.
stop_accepting({Pid, _Port}) ->
    try
        gen_server:call(Pid, stop_accepting)
    catch
        exit:_ -> ok
    end.

-doc "The port the listener bound to.".
-spec server_port(listener()) -> inet:port_number().
server_port({_Pid, Port}) -> Port.

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init(listen_opts()) -> {ok, state()} | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    case ssl_listen_opts(Opts) of
        {ok, SslOpts} -> listen(Opts, SslOpts);
        {error, Reason} -> {stop, Reason}
    end.

-spec handle_call(term(), {pid(), term()}, state()) ->
    {reply, term(), state()}.
handle_call(port, _From, State) ->
    {reply, State#state.port, State};
handle_call(new_connection, _From, #state{listen = undefined} = State) ->
    {reply, {error, stopping}, State};
handle_call(new_connection, _From, State) ->
    Args = State#state.conn_args,
    Pid = spawn_link(fun() -> connection_init(Args) end),
    {reply, {ok, Pid}, State#state{conns = maps:put(Pid, true, State#state.conns)}};
handle_call(stop_accepting, _From, State) ->
    %% Closing the listen socket is what stops the accept loops; each
    %% acceptor sees `{error, closed}' and exits. Connections already
    %% established keep running.
    _ = close_listen(State#state.listen),
    {reply, ok, State#state{listen = undefined, acceptors = []}};
handle_call(_, _, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'EXIT', Pid, _Reason}, State) ->
    {noreply, forget(Pid, State)};
handle_info(_, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, State) ->
    _ = close_listen(State#state.listen),
    %% A `normal' gen_server exit does not reach linked processes that do
    %% not trap exits, so the connections are killed explicitly. Each one
    %% takes its `serve_socket/2' peer, and with it the socket, down.
    _ = [exit(Pid, kill) || Pid <- maps:keys(State#state.conns)],
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_, State, _) -> {ok, State}.

%%====================================================================
%% Internals: listener
%%====================================================================

listen(Opts, SslOpts) ->
    case ssl:listen(maps:get(port, Opts, 0), SslOpts) of
        {ok, Listen} ->
            {ok, {_Addr, Bound}} = ssl:sockname(Listen),
            State = #state{
                listen = Listen,
                port = Bound,
                conn_args = conn_args(Opts)
            },
            {ok, start_acceptors(State, acceptor_count(Opts))};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

acceptor_count(Opts) ->
    maps:get(acceptors, Opts, erlang:system_info(schedulers)).

%% Precompute the three per-connection option maps: one per protocol the
%% dispatch can land on. Only the ALPN they record differs, and it is
%% fixed per branch, so nothing has to be rebuilt per connection.
conn_args(Opts) ->
    #{
        handshake_timeout => maps:get(handshake_timeout, Opts, ?DEFAULT_HANDSHAKE_TIMEOUT),
        h2 => livery_h2:serve_opts(Opts, ?H2),
        http1 => livery_h1:serve_opts(Opts, ?HTTP1),
        no_alpn => livery_h1:serve_opts(Opts, undefined)
    }.

start_acceptors(State, Count) ->
    Listen = State#state.listen,
    Self = self(),
    Pids = [spawn_link(fun() -> acceptor_loop(Self, Listen) end) || _ <- lists:seq(1, Count)],
    State#state{acceptors = Pids}.

%% Drop a dead child. An acceptor that died while we are still accepting
%% is replaced so the pool keeps its width; one that died because the
%% listen socket closed is simply forgotten.
forget(Pid, #state{listen = undefined} = State) ->
    State#state{
        acceptors = State#state.acceptors -- [Pid],
        conns = maps:remove(Pid, State#state.conns)
    };
forget(Pid, State) ->
    case lists:member(Pid, State#state.acceptors) of
        true ->
            Self = self(),
            Listen = State#state.listen,
            New = spawn_link(fun() -> acceptor_loop(Self, Listen) end),
            State#state{acceptors = [New | State#state.acceptors -- [Pid]]};
        false ->
            State#state{conns = maps:remove(Pid, State#state.conns)}
    end.

close_listen(undefined) -> ok;
close_listen(Listen) -> ssl:close(Listen).

%%====================================================================
%% Internals: acceptor
%%====================================================================

acceptor_loop(Listener, Listen) ->
    case ssl:transport_accept(Listen) of
        {ok, Socket} ->
            handoff(Listener, Socket),
            acceptor_loop(Listener, Listen);
        {error, Closed} when Closed =:= closed; Closed =:= einval ->
            ok;
        {error, _Transient} ->
            acceptor_loop(Listener, Listen)
    end.

%% The handshake runs in the connection process, not here, so a client
%% that opens a socket and then stalls costs one process instead of one
%% acceptor slot. The socket is transferred before the process is told
%% about it, so it never reads from a socket it does not own.
handoff(Listener, Socket) ->
    case gen_server:call(Listener, new_connection, infinity) of
        {ok, Pid} ->
            case ssl:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! {socket, Socket};
                {error, _} ->
                    exit(Pid, kill),
                    _ = ssl:close(Socket),
                    ok
            end;
        {error, stopping} ->
            _ = ssl:close(Socket),
            ok
    end.

%%====================================================================
%% Internals: per-connection dispatch
%%====================================================================

connection_init(Args) ->
    Timeout = maps:get(handshake_timeout, Args),
    receive
        {socket, Socket} -> handshake(Socket, Timeout, Args)
    after Timeout -> ok
    end.

handshake(Socket, Timeout, Args) ->
    case ssl:handshake(Socket, Timeout) of
        {ok, Tls} ->
            dispatch(Tls, Args);
        {error, _Reason} ->
            _ = ssl:close(Socket),
            ok
    end.

dispatch(Socket, Args) ->
    case ssl:negotiated_protocol(Socket) of
        {ok, ?H2} ->
            serve(fun h2:serve_socket/2, Socket, maps:get(h2, Args));
        {ok, ?HTTP1} ->
            serve(fun h1:serve_socket/2, Socket, maps:get(http1, Args));
        %% No ALPN is not a failure: a client that sent none is speaking
        %% HTTP/1.1, since RFC 9113 requires ALPN to reach h2 over TLS.
        {error, protocol_not_negotiated} ->
            serve(fun h1:serve_socket/2, Socket, maps:get(no_alpn, Args));
        _Unadvertised ->
            _ = ssl:close(Socket),
            ok
    end.

%% `serve_socket/2' hands the socket to a process linked to this one, so
%% this process has to outlive the connection: it waits for the peer to
%% go down, and its own death tears the connection down in turn.
serve(Serve, Socket, Opts) ->
    case Serve(Socket, Opts) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            receive
                {'DOWN', MRef, process, Pid, _Reason} -> ok
            end;
        {error, _Reason} ->
            _ = ssl:close(Socket),
            ok
    end.

%%====================================================================
%% Internals: TLS options
%%====================================================================

%% Mirrors the option contract h1 and h2 apply to their own listeners:
%% `verify_peer' requires `cacerts' (so a server asking for client
%% authentication without a trust anchor fails closed instead of
%% listening with it silently disabled) and implies a mandatory client
%% certificate, and user `ssl_opts' merge last so an override still wins.
ssl_listen_opts(Opts) ->
    case {maps:find(cert, Opts), maps:find(key, Opts)} of
        {{ok, Cert}, {ok, Key}} -> ssl_listen_opts(Cert, Key, Opts);
        _ -> {error, {missing_required_option, [cert, key]}}
    end.

ssl_listen_opts(Cert, Key, Opts) ->
    Verify = maps:get(verify, Opts, verify_none),
    CACerts = maps:get(cacerts, Opts, []),
    case {Verify, CACerts, alpn_protocols(Opts)} of
        {verify_peer, [], _} ->
            {error, verify_peer_requires_cacerts};
        {_, _, {error, _} = Error} ->
            Error;
        {_, _, {ok, Protocols}} ->
            Base =
                [
                    binary,
                    {active, false},
                    {packet, raw},
                    {reuseaddr, true},
                    {backlog, 1024},
                    {nodelay, true},
                    {certfile, to_list(Cert)},
                    {keyfile, to_list(Key)},
                    {alpn_preferred_protocols, Protocols},
                    %% h2 over TLS requires 1.2 or better (RFC 9113 s9.2).
                    {versions, ['tlsv1.2', 'tlsv1.3']},
                    {verify, Verify}
                ] ++ auth_opts(Verify, CACerts) ++ addr_opts(Opts),
            {ok, merge(Base, maps:get(ssl_opts, Opts, []))}
    end.

auth_opts(_Verify, []) -> [];
auth_opts(verify_peer, CACerts) -> [{cacerts, CACerts}, {fail_if_no_peer_cert, true}];
auth_opts(_Verify, CACerts) -> [{cacerts, CACerts}].

%% Server preference order: ssl picks the first entry the client also
%% offered, so `[h2, http1]' means h2 wins when both are on the table.
alpn_protocols(Opts) ->
    fold_protocols(maps:get(alpn, Opts, [h2, http1]), []).

fold_protocols([], Acc) -> {ok, lists:reverse(Acc)};
fold_protocols([h2 | Rest], Acc) -> fold_protocols(Rest, [?H2 | Acc]);
fold_protocols([http1 | Rest], Acc) -> fold_protocols(Rest, [?HTTP1 | Acc]);
fold_protocols([Other | _], _Acc) -> {error, {unknown_alpn_protocol, Other}}.

%% An IPv6 `ip' tuple selects the inet6 family, as it does on the
%% dedicated listeners.
addr_opts(Opts) ->
    case maps:find(ip, Opts) of
        {ok, IP} when tuple_size(IP) =:= 8 -> [inet6, {ip, IP}];
        {ok, IP} -> [{ip, IP}];
        error -> inet6_opt(maps:get(inet6, Opts, false))
    end.

inet6_opt(true) -> [inet6];
inet6_opt(false) -> [].

merge(Base, User) ->
    lists:foldl(fun replace/2, Base, User).

replace(Opt, Acc) when is_tuple(Opt) ->
    lists:keystore(element(1, Opt), 1, Acc, Opt);
replace(Opt, Acc) ->
    case lists:member(Opt, Acc) of
        true -> Acc;
        false -> Acc ++ [Opt]
    end.

to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) -> V.
