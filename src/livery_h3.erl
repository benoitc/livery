-module(livery_h3).
-moduledoc """
HTTP/3 adapter on top of the `quic` library's `quic_h3` subsystem.

Starts a `quic_h3` server bound to a Livery middleware stack and
handler. `quic_h3` runs the handler fun in a process of its own for
every request. In that process the adapter, as `livery_h1` and
`livery_h2` do:

1. Builds a `#livery_req{}` from the method, path, and headers
   delivered by `quic_h3`.
2. Registers the process as the stream handler
   (`quic_h3:set_stream_handler/4`), so the stream's body and trailer
   events, and any that arrived earlier, come to it. A stream already
   gone gets no worker.
3. Hands over to `livery_translator`, which starts the
   `livery_req_proc` worker and turns the `{quic_h3, Conn, _}` events
   into the `{livery_body, Ref, _}` messages the worker reads via
   `livery_body`, until the worker exits.

Response emission goes through `livery:emit/3` and lands on the
adapter callbacks, which call into `quic_h3:send_response/4`,
`quic_h3:send_data/3,4`, and `quic_h3:send_trailers/3`.
""".

-behaviour(livery_adapter).

-include("livery.hrl").

%% Default request-body ceiling (16 MiB); override with `max_body'
%% (`infinity' disables it). See livery_h1 for the rationale.
-define(DEFAULT_MAX_BODY, 16 * 1024 * 1024).

%% How long a send may stay refused by quic's send queue
%% (`send_queue_full') before the stream is reset.
-define(SEND_TIMEOUT, 30000).

%% Response bodies go to quic in pieces of at most this size, so a piece
%% refused for backpressure is cheap to send again.
-define(SEND_PIECE, 65536).

%% RFC 9114 Section 8.1: STOP_SENDING code for "the response is
%% complete, the rest of the request is not needed".
-define(H3_NO_ERROR, 16#100).

-export([start/1, accept_ws/4, accept_wt/4]).

-export([
    start/3,
    stop/1,
    send_headers/4,
    send_data/3,
    send_trailers/2,
    send_informational/3,
    reset/2,
    peer_info/1,
    capabilities/1
]).

-export_type([listen_opts/0, listener/0, stream/0]).

-type listener() :: atom().
-type stream() :: {pid(), non_neg_integer()}.

-type listen_opts() :: #{
    name => atom(),
    port => inet:port_number(),
    %% Bind address. An IPv6 8-tuple selects the inet6 family.
    ip => inet:ip_address(),
    %% Bind the IPv6 wildcard (`::') when no explicit `ip' is given.
    inet6 => boolean(),
    cert := binary(),
    key := term(),
    %% Client-certificate policy. `verify_peer' asks for (and requires) a
    %% client certificate, checked against `cacerts'; `quic' refuses to
    %% start the listener without them.
    cacerts => [binary()],
    verify => verify_none | verify_peer,
    %% Per-SNI certificate selection. Invoked per connection with the
    %% ClientHello SNI; the returned cert/key override the static
    %% `cert'/`key' for that handshake. Forwarded to `quic' (>= 1.6.5).
    sni_callback => fun(
        (binary() | undefined) ->
            {ok, #{cert := binary(), key := term(), cert_chain => [binary()]}}
            | {error, term()}
    ),
    settings => map(),
    quic_opts => map(),
    %% Extension hooks forwarded to `quic_h3' as is. `webtransport:h3_settings/0'
    %% sets all of them.
    stream_type_handler => fun(),
    h3_datagram_enabled => boolean(),
    connection_handler => fun(),
    stream_reset_final_size => boolean(),
    defer_requests_until_settings => boolean(),
    notify_streams_available => boolean(),
    %% Size of the `quic' connection worker pool, forwarded to `quic_h3'.
    pool_size => pos_integer(),
    max_body => non_neg_integer() | infinity,
    %% Shared service config, readable in handlers via livery_req:config/1.
    config => term(),
    stack := livery_middleware:stack(),
    handler := livery_middleware:handler()
}.

%%====================================================================
%% Public API
%%====================================================================

-doc """
Start a listener with the given options.

`Opts` must include `cert`, `key`, `stack`, and `handler`. `port`
defaults to 0 (random port). `name` defaults to a unique atom.
Returns the listener atom (passable to `stop/1` and
`quic:get_server_port/1`).

Pass an explicit, stable `name` if you start and stop listeners
repeatedly: `quic_h3` registers under an atom name, and an
auto-generated name mints a fresh atom per start (atoms are never
garbage-collected). `livery_service` derives a stable name from the
port for this reason.
""".
-spec start(listen_opts()) -> {ok, listener()} | {error, term()}.
start(Opts) when is_map(Opts) ->
    Name =
        case maps:find(name, Opts) of
            {ok, N} -> N;
            error -> fresh_name()
        end,
    case start(Name, Opts, #{}) of
        {ok, _Pid} -> {ok, Name};
        Other -> Other
    end.

%%====================================================================
%% livery_adapter callbacks
%%====================================================================

-spec start(atom() | undefined, listen_opts(), map()) ->
    {ok, pid()} | {error, term()}.
start(undefined, Opts, StartOpts) ->
    start(fresh_name(), Opts, StartOpts);
start(Name, Opts, _StartOpts) when is_atom(Name) ->
    maybe
        ok ?= livery_tls:check_listen_opts(Opts),
        H3Opts = build_h3_opts(Opts, maps:get(stack, Opts), maps:get(handler, Opts)),
        quic_h3:start_server(Name, maps:get(port, Opts, 0), H3Opts)
    end.

-spec stop(listener()) -> ok.
stop(Name) when is_atom(Name) ->
    _ = quic_h3:stop_server(Name),
    ok.

-spec send_headers(
    stream(),
    100..599,
    [{binary(), binary()}],
    livery_adapter:send_opts()
) ->
    livery_adapter:send_result().
send_headers({Conn, StreamId} = Stream, Status, Headers, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    with_retry(Stream, fun(Send) ->
        case Send(fun() -> quic_h3:send_response(Conn, StreamId, Status, Headers) end) of
            ok when EndStream -> Send(fun() -> quic_h3:send_data(Conn, StreamId, <<>>, true) end);
            Other -> Other
        end
    end).

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) ->
    livery_adapter:send_result().
send_data({Conn, StreamId} = Stream, IoData, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    Bin = iolist_to_binary(IoData),
    with_retry(Stream, fun(Send) -> send_pieces(Conn, StreamId, Bin, EndStream, Send) end).

-spec send_trailers(stream(), [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_trailers({Conn, StreamId} = Stream, Trailers) ->
    with_retry(Stream, fun(Send) ->
        Send(fun() -> quic_h3:send_trailers(Conn, StreamId, Trailers) end)
    end).

-spec send_pieces(
    pid(), non_neg_integer(), binary(), boolean(), fun((fun(() -> R)) -> R)
) -> R when
    R :: livery_adapter:send_result().
send_pieces(Conn, StreamId, Bin, EndStream, Send) when byte_size(Bin) =< ?SEND_PIECE ->
    Send(fun() -> quic_h3:send_data(Conn, StreamId, Bin, EndStream) end);
send_pieces(Conn, StreamId, Bin, EndStream, Send) ->
    <<Piece:?SEND_PIECE/binary, Rest/binary>> = Bin,
    case Send(fun() -> quic_h3:send_data(Conn, StreamId, Piece, false) end) of
        ok -> send_pieces(Conn, StreamId, Rest, EndStream, Send);
        Other -> Other
    end.

%% Run a sequence of quic sends sharing one deadline. `Body' gets a
%% `Send' fun that retries a single send while quic refuses it with
%% `send_queue_full'. A send still refused at the deadline resets the
%% stream: the peer has stopped reading, and holding the worker longer
%% only keeps the response queued.
-spec with_retry(stream(), fun((fun((fun(() -> R)) -> R)) -> R)) ->
    R | {error, closed | send_timeout}
when
    R :: livery_adapter:send_result().
with_retry(Stream, Body) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SEND_TIMEOUT,
    Send = fun(Fun) -> livery_send_retry:run(Fun, Deadline) end,
    case closed_guard(fun() -> Body(Send) end) of
        {error, send_timeout} = Error ->
            ok = livery_disconnect:local_reset(),
            ok = reset(Stream, send_timeout),
            Error;
        Other ->
            Other
    end.

%% A send to a connection whose process has gone away (peer closed) exits
%% the underlying gen_statem:call with noproc/normal/shutdown. Map that to
%% {error, closed} so livery:emit/3 treats it as a normal disconnect, not a
%% handler crash. See livery_h2:closed_guard/1 for the full rationale.
-spec closed_guard(fun(() -> R)) -> R | {error, closed}.
closed_guard(Fun) ->
    try
        Fun()
    catch
        exit:{noproc, _} -> {error, closed};
        exit:{normal, _} -> {error, closed};
        exit:{{shutdown, _}, _} -> {error, closed}
    end.

-spec reset(stream(), term()) -> ok.
reset({Conn, StreamId}, _Reason) ->
    _ = quic_h3:cancel(Conn, StreamId),
    ok.

%% Interim (1xx) responses are not surfaced by the h3 engine yet.
-spec send_informational(stream(), 100..199, [{binary(), binary()}]) ->
    {error, unsupported}.
send_informational(_Stream, _Status, _Headers) ->
    {error, unsupported}.

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info({Conn, _StreamId}) ->
    #{peer => h3_peer(Conn), tls => undefined, alpn => <<"h3">>}.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_Listener) ->
    #{
        trailers => true,
        extended_connect => true,
        datagrams => true,
        capsules => true,
        informational => false
    }.

%%====================================================================
%% WebSocket handoff (RFC 9220 extended CONNECT)
%%====================================================================

-doc """
Accept a WebSocket session on an extended-CONNECT H3 stream.

Validates the RFC 9220 handshake, replies `200`, then hands the
stream to the `ws` library driven by the `livery_ws_h3` transport.
""".
-spec accept_ws(stream(), livery_req:req(), module(), term()) ->
    {ok, pid()} | {error, term()}.
accept_ws({Conn, StreamId}, Req, HandlerMod, Opts) ->
    {ValidateOpts, AcceptOpts0} = livery_ws:handshake_opts(Opts),
    Pseudo = connect_pseudo_headers(Req, <<"websocket">>),
    case ws_h3_upgrade:validate_request(Pseudo, ValidateOpts) of
        {ok, Info} ->
            {ExtHeaders, AcceptOpts} = livery_ws:deflate_opts(Info, Opts, AcceptOpts0),
            RespHeaders = drop_status(ws_h3_upgrade:response_headers(Info)) ++ ExtHeaders,
            case quic_h3:send_response(Conn, StreamId, 200, RespHeaders) of
                ok ->
                    WsReq = #{
                        method => <<"CONNECT">>,
                        path => livery_req:path(Req),
                        headers => livery_req:headers(Req),
                        peer => h3_peer(Conn)
                    },
                    ws:accept(
                        livery_ws_h3,
                        {Conn, StreamId},
                        WsReq,
                        HandlerMod,
                        Opts,
                        AcceptOpts
                    );
                Err ->
                    {error, {send_response_failed, Err}}
            end;
        {error, Reason} ->
            {error, {bad_request, Reason}}
    end.

drop_status(Headers) ->
    [{N, V} || {N, V} <- Headers, N =/= <<":status">>].

%% The h3 request does not carry the peer, but the underlying QUIC
%% connection knows it. Reach it via quic_h3:get_quic_conn/1. A
%% connection that is already gone reads as undefined instead of
%% crashing the caller.
-spec h3_peer(term()) -> {inet:ip_address(), inet:port_number()} | undefined.
h3_peer(Conn) ->
    try quic_connection:peername(quic_h3:get_quic_conn(Conn)) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    catch
        exit:_ -> undefined
    end.

%%====================================================================
%% WebTransport handoff (called by livery_wt:upgrade/3)
%%====================================================================

-doc """
Hand an extended-CONNECT stream to the `webtransport` library
with `transport => h3`.
""".
-spec accept_wt(stream(), livery_req:req(), module(), term()) ->
    {ok, pid()} | {error, term()}.
accept_wt({Conn, StreamId}, Req, HandlerMod, Opts) ->
    Headers = connect_pseudo_headers(Req, wt_protocol(Req)),
    webtransport:accept(Conn, StreamId, Headers, Opts#{
        transport => h3,
        handler => HandlerMod,
        handler_opts => maps:get(handler_opts, Opts, #{})
    }).

%% The `:protocol' value the client sent. WebTransport drafts differ here:
%% draft-02 says `webtransport', draft-15 says `webtransport-h3', and the
%% `webtransport' library picks its compatibility mode from it. The H3
%% adapter keeps pseudo-headers in the request's header list, so the real
%% value is available; fall back to the draft-02 spelling only if it is not.
-spec wt_protocol(livery_req:req()) -> binary().
wt_protocol(Req) ->
    livery_req:header(<<":protocol">>, Req, <<"webtransport">>).

-spec connect_pseudo_headers(livery_req:req(), binary()) ->
    [{binary(), binary()}].
connect_pseudo_headers(Req, Protocol) ->
    Path =
        case livery_req:query(Req) of
            <<>> -> livery_req:path(Req);
            Query -> <<(livery_req:path(Req))/binary, "?", Query/binary>>
        end,
    %% Pseudo-headers are rebuilt below from the request fields; drop any
    %% copies the adapter kept so none appears twice.
    Regular = [H || {Name, _} = H <- livery_req:headers(Req), not is_pseudo(Name)],
    [
        {<<":method">>, livery_req:method(Req)},
        {<<":protocol">>, Protocol},
        {<<":scheme">>, livery_req:scheme(Req)},
        {<<":authority">>, livery_req:authority(Req)},
        {<<":path">>, Path}
        | Regular
    ].

-spec is_pseudo(binary()) -> boolean().
is_pseudo(<<$:, _/binary>>) -> true;
is_pseudo(_) -> false.

%%====================================================================
%% Internals: per-request dispatch
%%====================================================================

-spec fresh_name() -> atom().
fresh_name() ->
    list_to_atom("livery_h3_" ++ integer_to_list(erlang:unique_integer([positive, monotonic]))).

-spec build_h3_opts(
    listen_opts(),
    livery_middleware:stack(),
    livery_middleware:handler()
) -> map().
build_h3_opts(Opts, Stack, Handler) ->
    MaxBody = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
    Base = #{
        cert => maps:get(cert, Opts),
        key => maps:get(key, Opts),
        quic_opts => quic_opts(Opts),
        handler => make_handler_fun(Stack, Handler, MaxBody, maps:get(config, Opts, undefined))
    },
    copy_keys(
        [
            settings,
            stream_type_handler,
            h3_datagram_enabled,
            connection_handler,
            cacerts,
            %% WebTransport draft-17 needs the client's SETTINGS before the
            %% request is accepted (they pick the draft), the final size of
            %% reset streams for its flow control, and to hear when a stream
            %% refused at the peer's limit can be opened again.
            defer_requests_until_settings,
            stream_reset_final_size,
            notify_streams_available,
            %% Number of UDP listener processes. >1 enables SO_REUSEPORT
            %% so the kernel spreads packets across readers, letting H3
            %% use more than one core for transport.
            pool_size
        ],
        Opts,
        Base
    ).

%% Build the `quic_opts' map handed to `quic_h3'. Folds the `ip'/`inet6'
%% bind options into `extra_socket_opts' (an IPv6 `ip' tuple or
%% `inet6 => true' selects the inet6 family; caller-supplied
%% `extra_socket_opts' are preserved) and carries `sni_callback' and the
%% client-certificate policy here so they reach `quic:start_server'
%% (`quic_h3' only lifts cert/key/cacerts from the top level).
-spec quic_opts(listen_opts()) -> map().
quic_opts(Opts) ->
    QuicOpts0 = maps:get(quic_opts, Opts, #{}),
    QuicOpts1 =
        case livery_inet:socket_addr_opts(Opts) of
            [] ->
                QuicOpts0;
            Addr ->
                Extra = maps:get(extra_socket_opts, QuicOpts0, []),
                QuicOpts0#{extra_socket_opts => Addr ++ Extra}
        end,
    QuicOpts2 =
        case maps:get(verify, Opts, verify_none) of
            verify_peer -> QuicOpts1#{require_client_cert => true};
            verify_none -> QuicOpts1
        end,
    case maps:find(sni_callback, Opts) of
        {ok, Fun} -> QuicOpts2#{sni_callback => Fun};
        error -> QuicOpts2
    end.

-spec copy_keys([atom()], map(), map()) -> map().
copy_keys([], _Src, Dst) ->
    Dst;
copy_keys([K | Rest], Src, Dst) ->
    case maps:find(K, Src) of
        {ok, V} -> copy_keys(Rest, Src, maps:put(K, V, Dst));
        error -> copy_keys(Rest, Src, Dst)
    end.

-spec make_handler_fun(
    livery_middleware:stack(),
    livery_middleware:handler(),
    non_neg_integer() | infinity,
    term()
) ->
    fun(
        (
            pid(),
            non_neg_integer(),
            binary(),
            binary(),
            [{binary(), binary()}]
        ) -> ok
    ).
make_handler_fun(Stack, Handler, MaxBody, Config) ->
    Ctx = #{stack => Stack, handler => Handler, max_body => MaxBody, config => Config},
    fun(Conn, StreamId, Method, Path, Headers) ->
        serve_request(Conn, StreamId, Method, Path, Headers, Ctx)
    end.

%% Runs in the process quic_h3 spawned for the request, which becomes
%% the request's translator (livery_translator). It registers first:
%% quic_h3 then replays what already arrived into this mailbox, in order.
%% A stream that is already gone (the client left) gets no worker.
-spec serve_request(
    pid(), non_neg_integer(), binary(), binary(), [{binary(), binary()}], map()
) -> ok.
serve_request(Conn, StreamId, Method, Path, Headers, Ctx) ->
    {RawPath, RawQuery} = livery_translator:split_query(Path),
    Req = build_req(Conn, StreamId, Method, RawPath, Headers),
    Registered = closed_guard(fun() ->
        quic_h3:set_stream_handler(Conn, StreamId, self(), #{drain_buffer => false})
    end),
    case Registered of
        {error, _} ->
            ok;
        _ ->
            livery_translator:serve(Req, Ctx#{
                adapter => ?MODULE,
                stream => {Conn, StreamId},
                raw_query => RawQuery,
                wire => #{
                    tag => quic_h3,
                    key => Conn,
                    classify => fun(Event) -> classify(StreamId, Event) end,
                    conn => Conn,
                    %% The response is out; STOP_SENDING tells the client to
                    %% stop sending the rest (RFC 9114 Section 4.1.1). The
                    %% client answers with RESET_STREAM, which makes quic_h3
                    %% drop the stream.
                    on_abandoned => fun() ->
                        quic:stop_sending(quic_h3:get_quic_conn(Conn), StreamId, ?H3_NO_ERROR)
                    end
                }
            })
    end.

%% The quic_h3 events of this request, in livery_translator's terms.
%% quic_h3 reports a connection close to the owner only, so the
%% translator learns of a disconnect from the connection's DOWN.
-spec classify(non_neg_integer(), term()) -> livery_translator:event().
classify(StreamId, {data, StreamId, Chunk, Fin}) -> {data, Chunk, Fin};
classify(StreamId, {trailers, StreamId, Trailers}) -> {trailers, Trailers};
classify(StreamId, {stream_reset, StreamId, Reason}) -> {reset, Reason};
classify(_StreamId, _Event) -> ignore.

-spec build_req(
    pid(),
    non_neg_integer(),
    binary(),
    binary(),
    [{binary(), binary()}]
) -> livery_req:req().
build_req(Conn, StreamId, Method, Path, Headers) ->
    livery_req:new(#{
        protocol => h3,
        method => Method,
        %% HTTP/3 always runs over TLS.
        scheme => proplists:get_value(<<":scheme">>, Headers, <<"https">>),
        authority => proplists:get_value(<<":authority">>, Headers, <<>>),
        path => Path,
        headers => Headers,
        adapter => ?MODULE,
        stream => {Conn, StreamId},
        engine_pid => Conn,
        peer => h3_peer(Conn),
        %% HTTP/3 always runs over TLS, so the map is always there.
        tls => livery_tls:peer(fun() -> quic:peercert(quic_h3:get_quic_conn(Conn)) end)
    }).
