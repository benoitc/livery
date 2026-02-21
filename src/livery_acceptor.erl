%% @doc Acceptor process with SO_REUSEPORT support.
%%
%% Each acceptor opens its own listen socket with SO_REUSEPORT enabled,
%% allowing the kernel to load-balance connections across acceptors.
-module(livery_acceptor).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-record(state, {
    listen_socket :: gen_tcp:socket() | ssl:sslsocket() | undefined,
    transport :: gen_tcp | ssl,
    handler :: module(),
    handler_opts :: term(),
    port :: inet:port_number(),
    ssl_opts :: list(),
    ref :: reference() | undefined
}).

%% API

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% gen_server callbacks

-spec init(map()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    Port = maps:get(port, Opts),
    Handler = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, []),
    SslOpts = maps:get(ssl_opts, Opts, []),
    Transport = case SslOpts of
        [] -> gen_tcp;
        _ -> ssl
    end,

    %% Open listen socket with SO_REUSEPORT
    case open_listen_socket(Port, Transport, SslOpts) of
        {ok, ListenSocket} ->
            State = #state{
                listen_socket = ListenSocket,
                transport = Transport,
                handler = Handler,
                handler_opts = HandlerOpts,
                port = Port,
                ssl_opts = SslOpts
            },
            %% Start accepting
            {ok, accept_loop(State)};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_info({'$gen_accept', Ref, {ok, Socket, NegotiatedProto}}, #state{ref = Ref} = State) ->
    %% New connection accepted
    handle_new_connection(Socket, NegotiatedProto, State),
    {noreply, accept_loop(State)};

handle_info({'$gen_accept', Ref, {error, closed}}, #state{ref = Ref} = State) ->
    %% Listen socket closed
    {stop, normal, State};

handle_info({'$gen_accept', Ref, {error, Reason}}, #state{ref = Ref} = State) ->
    %% Accept error, try again
    error_logger:warning_msg("Accept error: ~p~n", [Reason]),
    {noreply, accept_loop(State)};

handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{listen_socket = undefined}) ->
    ok;
terminate(_Reason, #state{listen_socket = Socket, transport = gen_tcp}) ->
    gen_tcp:close(Socket),
    ok;
terminate(_Reason, #state{listen_socket = Socket, transport = ssl}) ->
    ssl:close(Socket),
    ok.

%% Internal functions

open_listen_socket(Port, gen_tcp, _SslOpts) ->
    TcpOpts = [
        binary,
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 1024},
        {packet, raw}
    ] ++ reuseport_opts(),
    gen_tcp:listen(Port, TcpOpts);

open_listen_socket(Port, ssl, SslOpts) ->
    TcpOpts = [
        binary,
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 1024},
        {packet, raw}
    ] ++ reuseport_opts(),
    %% Add ALPN configuration for HTTP/2 and HTTP/1.1 negotiation
    AlpnOpts = [{alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}],
    ssl:listen(Port, TcpOpts ++ AlpnOpts ++ SslOpts).

reuseport_opts() ->
    %% SO_REUSEPORT options (Linux and macOS/FreeBSD)
    case os:type() of
        {unix, linux} ->
            [{raw, 1, 15, <<1:32/native>>}]; %% SOL_SOCKET=1, SO_REUSEPORT=15
        {unix, darwin} ->
            [{raw, 16#ffff, 16#0200, <<1:32/native>>}]; %% SOL_SOCKET=0xffff, SO_REUSEPORT=0x0200
        {unix, freebsd} ->
            [{raw, 16#ffff, 16#0200, <<1:32/native>>}]; %% Same as macOS
        _ ->
            [] %% No SO_REUSEPORT on other platforms
    end.

accept_loop(#state{listen_socket = ListenSocket, transport = gen_tcp} = State) ->
    %% Use async accept
    Ref = make_ref(),
    Self = self(),
    spawn_link(fun() ->
        case gen_tcp:accept(ListenSocket) of
            {ok, Socket} ->
                %% Transfer socket ownership to the gen_server BEFORE exiting
                ok = gen_tcp:controlling_process(Socket, Self),
                %% TCP connections use undefined - protocol detected via preface
                Self ! {'$gen_accept', Ref, {ok, Socket, undefined}};
            {error, Reason} ->
                Self ! {'$gen_accept', Ref, {error, Reason}}
        end
    end),
    State#state{ref = Ref};

accept_loop(#state{listen_socket = ListenSocket, transport = ssl} = State) ->
    %% Use async accept for SSL
    Ref = make_ref(),
    Self = self(),
    spawn_link(fun() ->
        case ssl:transport_accept(ListenSocket) of
            {ok, TlsSocket} ->
                case ssl:handshake(TlsSocket, 5000) of
                    {ok, SslSocket} ->
                        %% Check ALPN negotiated protocol
                        NegotiatedProto = case ssl:negotiated_protocol(SslSocket) of
                            {ok, <<"h2">>} -> h2;
                            {ok, <<"http/1.1">>} -> h1;
                            {error, protocol_not_negotiated} -> undefined
                        end,
                        %% Transfer socket ownership to the gen_server BEFORE exiting
                        ok = ssl:controlling_process(SslSocket, Self),
                        Self ! {'$gen_accept', Ref, {ok, SslSocket, NegotiatedProto}};
                    {error, Reason} ->
                        ssl:close(TlsSocket),
                        Self ! {'$gen_accept', Ref, {error, Reason}}
                end;
            {error, Reason} ->
                Self ! {'$gen_accept', Ref, {error, Reason}}
        end
    end),
    State#state{ref = Ref}.

handle_new_connection(Socket, NegotiatedProto, #state{transport = Transport,
                                                       handler = Handler,
                                                       handler_opts = HandlerOpts}) ->
    %% Hand off socket to new connection process
    case livery_connection:start_link(Socket, Transport, Handler, HandlerOpts, NegotiatedProto) of
        {ok, Pid} ->
            %% Transfer socket ownership
            case transfer_socket(Socket, Transport, Pid) of
                ok ->
                    %% Signal the connection process that it now owns the socket
                    Pid ! activate_socket;
                {error, closed} ->
                    %% Socket was closed, connection process will handle this
                    ok;
                {error, _Reason} ->
                    close_socket(Socket, Transport)
            end;
        {error, _Reason} ->
            close_socket(Socket, Transport)
    end.

transfer_socket(Socket, gen_tcp, Pid) ->
    gen_tcp:controlling_process(Socket, Pid);
transfer_socket(Socket, ssl, Pid) ->
    ssl:controlling_process(Socket, Pid).

close_socket(Socket, gen_tcp) ->
    gen_tcp:close(Socket);
close_socket(Socket, ssl) ->
    ssl:close(Socket).
