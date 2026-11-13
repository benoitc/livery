-module(livery_h1).
-moduledoc """
HTTP/1.1 adapter on top of the `h1` library.

Starts an `h1` server bound to a Livery middleware stack and
handler. `h1` runs the handler fun in a process of its own for every
request and delivers that request's body and trailer events to it as
`{h1_stream, StreamId, _}` messages. In that process the adapter:

1. Builds a `#livery_req{}` from the method, path, and headers
   delivered by `h1`.
2. Hands over to `livery_translator`, which starts the
   `livery_req_proc` worker and turns the `{h1_stream, StreamId, _}`
   events into the `{livery_body, Ref, _}` messages the worker reads via
   `livery_body`, until the worker exits.

Response emission goes through `livery:emit/3` and lands on the
adapter callbacks (`send_headers/4`, `send_full/5`, `send_data/3`,
`send_trailers/2`, `reset/2`), which in turn call into
`h1:send_response/4`, `h1:respond/5`, `h1:send_data/3,4`, and
`h1:send_trailers/3`. Full bodies coalesce into a single
content-length write via `send_full/5` -> `h1:respond/5`.
""".

-behaviour(livery_adapter).

-include("livery.hrl").

%% Default request-body ceiling (16 MiB). Bounds how much body the
%% translator forwards into the worker mailbox; override per listener
%% with the `max_body' option (`infinity' disables it).
-define(DEFAULT_MAX_BODY, 16 * 1024 * 1024).

%% Options that configure the listen socket and the acceptor pool. They
%% only apply when livery owns the listen socket, so `serve_opts/2' drops
%% them.
-define(LISTEN_KEYS, [
    ip,
    inet6,
    cert,
    key,
    cacerts,
    verify,
    ssl_opts,
    acceptors,
    handshake_timeout
]).

%% Per-connection options. h1 selects exactly this set into its connection
%% opts, so both the listener and the serve-an-accepted-socket path forward
%% all of them.
-define(CONN_KEYS, [
    idle_timeout,
    request_timeout,
    early_response_drain,
    lingering_timeout,
    max_keepalive_requests,
    pipeline,
    max_line_length,
    max_request_line_size,
    max_empty_lines,
    max_header_name_size,
    max_header_value_size,
    max_headers,
    max_header_block_size
]).

%% Public API
-export([start/1, stop_accepting/1, accept_ws/4, serve_opts/2]).

%% livery_adapter callbacks
-export([
    start/3,
    stop/1,
    send_headers/4,
    send_full/5,
    send_data/3,
    send_trailers/2,
    send_informational/3,
    reset/2,
    peer_info/1,
    capabilities/1
]).

-export_type([listen_opts/0, listener/0, stream/0]).

-type listener() :: h1:server_ref().
%% The third element is the protocol ALPN settled on for this connection
%% (`undefined' when the client offered none, or when the listener is
%% cleartext). It is carried here rather than looked up because only the
%% process that handshaked the socket ever knows it.
-type stream() :: {h1:connection(), h1:stream_id(), binary() | undefined}.

-type listen_opts() :: #{
    port => inet:port_number(),
    %% Bind address. An IPv6 8-tuple selects the inet6 family.
    ip => inet:ip_address(),
    %% Bind the IPv6 wildcard (`::') when no explicit `ip' is given.
    inet6 => boolean(),
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    %% Client-certificate policy. `verify_peer' asks for (and requires) a
    %% client certificate and needs `cacerts'; h1 rejects the pair otherwise
    %% rather than listening with authentication silently off.
    verify => verify_none | verify_peer,
    ssl_opts => [ssl:tls_server_option()],
    acceptors => pos_integer(),
    %% Authoritative request-body ceiling: a body past it yields a graceful
    %% 413, `infinity' disables it, default 16 MiB. This drives h1's parser
    %% cap too (h1's own 8 MiB default is disabled in its favour), so a value
    %% above 8 MiB takes effect instead of being silently capped.
    max_body => non_neg_integer() | infinity,
    %% Slow-client guards, passed through to `h1'. They have finite
    %% defaults there (idle_timeout 300000 ms, request_timeout 60000 ms),
    %% so a slow-loris client is already bounded; tighten for an
    %% edge-facing listener.
    idle_timeout => timeout(),
    request_timeout => timeout(),
    handshake_timeout => timeout(),
    %% Early-response inbound-drain budget (lingering close): when a
    %% handler responds before the request body is fully read, h1 drains
    %% the leftover body before closing so the client reads the response.
    %% `{MaxBytes, MaxMs}' (either component `infinity'), `0' disables.
    %% Defaults to h1's `{infinity, 30000}'. `lingering_timeout => Ms' is
    %% the time-only form.
    early_response_drain => 0 | {non_neg_integer() | infinity, non_neg_integer() | infinity},
    lingering_timeout => timeout(),
    max_keepalive_requests => pos_integer() | infinity,
    %% Serve pipelined requests concurrently rather than one at a time.
    pipeline => boolean(),
    %% Parser size limits, passed through to `h1'. All have finite defaults
    %% there; tighten them for an edge-facing listener. `max_request_line_size'
    %% caps the whole request line (method + target + version) and yields 414,
    %% `max_line_length' only bounds an unterminated line. Header breaches
    %% yield 431. Requires erlang_h1 >= 0.9.0 for `max_request_line_size'.
    max_line_length => pos_integer(),
    max_request_line_size => pos_integer() | infinity,
    max_empty_lines => non_neg_integer(),
    max_header_name_size => pos_integer(),
    max_header_value_size => pos_integer(),
    max_headers => pos_integer(),
    max_header_block_size => pos_integer(),
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

`Opts` must include `stack` and `handler`. `port` defaults to 0
(random port). `transport` defaults to `tcp`. Returns the same
listener handle the `h1` library does, suitable for passing to
`stop/1` or to `h1:server_port/1`.
""".
-spec start(listen_opts()) -> {ok, listener()} | {error, term()}.
start(Opts) when is_map(Opts) ->
    start(undefined, Opts, #{}).

%%====================================================================
%% livery_adapter callbacks
%%====================================================================

-spec start(atom() | undefined, listen_opts(), map()) ->
    {ok, listener()} | {error, term()}.
start(_Name, Opts, _StartOpts) ->
    case livery_tls:check_listen_opts(Opts) of
        ok ->
            H1Opts = build_h1_opts(Opts, maps:get(stack, Opts), maps:get(handler, Opts)),
            h1:start_server(maps:get(port, Opts, 0), H1Opts);
        {error, _} = E ->
            E
    end.

-spec stop(listener()) -> ok.
%% Synchronous (h1 >= 0.8.0): closes the listen socket, the acceptor
%% pool, and every accepted connection before returning.
stop(Listener) ->
    _ = h1:stop_server(Listener),
    ok.

-doc """
Stop accepting new connections while continuing to serve the
established ones. Used by `livery_drain` for graceful shutdown;
`stop/1` afterwards closes the remaining connections.
""".
-spec stop_accepting(listener()) -> ok.
stop_accepting(Listener) ->
    _ = h1:stop_accepting(Listener),
    ok.

-spec send_headers(
    stream(),
    100..599,
    [{binary(), binary()}],
    livery_adapter:send_opts()
) ->
    livery_adapter:send_result().
send_headers({Conn, StreamId, _Alpn}, Status, Headers, Opts) ->
    closed_guard(fun() ->
        case {maps:get(end_stream, Opts, false), drain_opts(Opts)} of
            {true, {ok, RespOpts}} ->
                %% Empty-body early response with a per-response drain budget:
                %% commit it via respond/6 so h1 honors the budget on close.
                h1:respond(Conn, StreamId, Status, Headers, <<>>, RespOpts);
            {EndStream, _} ->
                case h1:send_response(Conn, StreamId, Status, Headers) of
                    ok when EndStream -> h1:send_data(Conn, StreamId, <<>>, true);
                    ok -> ok;
                    Other -> Other
                end
        end
    end).

-spec send_full(
    stream(),
    100..599,
    [{binary(), binary()}],
    iodata(),
    livery_adapter:send_opts()
) ->
    livery_adapter:send_result().
%% Coalesce a full response (headers + body) into a single content-length
%% write via h1:respond/5, instead of the granular send_headers/send_data
%% path which frames the body as chunked. livery:emit/3 picks this up
%% because the callback is exported. A per-response early-response drain
%% budget routes through respond/6 so h1 honors it on an early close.
send_full({Conn, StreamId, _Alpn}, Status, Headers, IoData, Opts) ->
    closed_guard(fun() ->
        case drain_opts(Opts) of
            {ok, RespOpts} -> h1:respond(Conn, StreamId, Status, Headers, IoData, RespOpts);
            none -> h1:respond(Conn, StreamId, Status, Headers, IoData)
        end
    end).

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) ->
    livery_adapter:send_result().
send_data({Conn, StreamId, _Alpn}, IoData, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    closed_guard(fun() -> h1:send_data(Conn, StreamId, IoData, EndStream) end).

-spec send_trailers(stream(), [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_trailers({Conn, StreamId, _Alpn}, Trailers) ->
    closed_guard(fun() -> h1:send_trailers(Conn, StreamId, Trailers) end).

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

-spec send_informational(stream(), 100..199, [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_informational({Conn, StreamId, _Alpn}, Status, Headers) ->
    closed_guard(fun() -> h1:send_informational(Conn, StreamId, Status, Headers) end).

-spec reset(stream(), term()) -> ok.
reset({Conn, StreamId, _Alpn}, Reason) ->
    _ = h1:cancel_stream(Conn, StreamId, Reason),
    ok.

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info({Conn, _StreamId, Alpn}) ->
    #{peer => conn_peer(Conn), tls => undefined, alpn => Alpn}.

%% The h1 connection records the peer at accept time (h1 >= 0.8.0).
-spec conn_peer(h1:connection()) ->
    {inet:ip_address(), inet:port_number()} | undefined.
conn_peer(Conn) ->
    try h1:peername(Conn) of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    catch
        exit:_ -> undefined
    end.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_Listener) ->
    #{
        trailers => true,
        extended_connect => false,
        datagrams => false,
        capsules => false,
        informational => true
    }.

%% Translate the per-response `early_response_drain' send-opt into the
%% h1:respond/6 options map. Absent or `default' yields `none' (h1 uses
%% the listener budget); any other value produces the per-response map.
-spec drain_opts(livery_adapter:send_opts()) -> {ok, h1:respond_opts()} | none.
drain_opts(Opts) ->
    case maps:get(early_response_drain, Opts, default) of
        default -> none;
        Drain -> {ok, #{early_response_drain => to_h1(Drain)}}
    end.

%% `none' disables the drain (h1's `0'); a `{MaxBytes, MaxMs}' budget
%% passes straight through.
-spec to_h1(none | {non_neg_integer() | infinity, non_neg_integer() | infinity}) ->
    h1:early_response_drain().
to_h1(none) -> 0;
to_h1({MaxBytes, MaxMs}) -> {MaxBytes, MaxMs}.

%%====================================================================
%% WebSocket handoff (called by livery_ws:upgrade/3)
%%====================================================================

-doc """
Hand the stream's socket to the `ws` library to run a WebSocket
session.

Validates the RFC 6455 handshake headers (negotiating a
subprotocol when `Opts` carries `subprotocols`), replies 101 via
`h1:accept_upgrade/3`, takes ownership of the raw socket, and
calls `ws:accept/6` with the supplied handler module, opts, and
any `idle_timeout`. The handler's `Req` carries the socket `peer`.

Returns `{ok, SessionPid}` on success or `{error, _}` on a bad
handshake or socket transfer failure.
""".
-spec accept_ws(
    stream(),
    livery_req:req(),
    module(),
    term()
) ->
    {ok, pid()} | {error, term()}.
accept_ws({Conn, StreamId, _Alpn}, Req, HandlerMod, Opts) ->
    {ValidateOpts, AcceptOpts0} = livery_ws:handshake_opts(Opts),
    Headers = livery_req:headers(Req),
    case ws_h1_upgrade:validate_request(Headers, ValidateOpts) of
        {ok, Info} ->
            {ExtHeaders, AcceptOpts} = livery_ws:deflate_opts(Info, Opts, AcceptOpts0),
            RespHeaders = ws_h1_upgrade:response_headers(Info) ++ ExtHeaders,
            case h1:accept_upgrade(Conn, StreamId, RespHeaders) of
                {ok, Socket, _BufferedBytes} ->
                    WsReq = build_ws_req(Req, Socket),
                    ws:accept(
                        ws_transport(Req),
                        Socket,
                        WsReq,
                        HandlerMod,
                        Opts,
                        AcceptOpts
                    );
                {error, Reason} ->
                    {error, {accept_upgrade_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {bad_request, Reason}}
    end.

-spec build_ws_req(livery_req:req(), term()) -> map().
build_ws_req(Req, Socket) ->
    #{
        method => livery_req:method(Req),
        path => livery_req:path(Req),
        query => livery_req:query(Req),
        headers => livery_req:headers(Req),
        peer => socket_peer(Req, Socket)
    }.

%% The h1 library does not carry the peer on the request, but the accepted
%% upgrade socket does. Read it with the transport matching the listener's
%% security (same branch as ws_transport/1).
-spec socket_peer(livery_req:req(), term()) ->
    {inet:ip_address(), inet:port_number()} | undefined.
socket_peer(Req, Socket) ->
    Res =
        case livery_req:tls(Req) of
            undefined -> inet:peername(Socket);
            _ -> ssl:peername(Socket)
        end,
    case Res of
        {ok, Peer} -> Peer;
        {error, _} -> undefined
    end.

%% Pick the ws transport from the connection's security, which the
%% listener records on the request (an ssl listener sets `tls'). This
%% reads the listener's own configuration rather than inspecting the
%% opaque socket representation. Mirrors `ws_client', which selects the
%% transport from the `ws://' / `wss://' scheme.
-spec ws_transport(livery_req:req()) -> ws_transport_gen_tcp | ws_transport_ssl.
ws_transport(Req) ->
    case livery_req:tls(Req) of
        undefined -> ws_transport_gen_tcp;
        _ -> ws_transport_ssl
    end.

%%====================================================================
%% Internals: per-request dispatch
%%====================================================================

-spec build_h1_opts(
    listen_opts(),
    livery_middleware:stack(),
    livery_middleware:handler()
) -> map().
build_h1_opts(Opts, Stack, Handler) ->
    Transport = maps:get(transport, Opts, tcp),
    Base = conn_base(Opts, Stack, Handler, Transport, listener_alpn(Transport)),
    copy_keys(?LISTEN_KEYS ++ ?CONN_KEYS, Opts, Base#{transport => Transport}).

%% A dedicated TLS listener advertises `http/1.1' and nothing else, so
%% that is what ALPN settles on; a cleartext listener negotiates nothing.
%% The multiplexed listener knows the real value and passes it to
%% `serve_opts/1' instead.
-spec listener_alpn(tcp | ssl) -> binary() | undefined.
listener_alpn(ssl) -> <<"http/1.1">>;
listener_alpn(tcp) -> undefined.

-doc """
Build the `h1:serve_socket/2` option map for a socket the caller
already accepted and handshaked.

Used by `livery_h1h2` after ALPN settles on `http/1.1`. `Opts` is
the listener's `listen_opts()`; `Alpn` is the protocol actually
negotiated (`undefined` when the client offered none). Listen-time
keys (`cert`, `acceptors`, ...) are dropped: the socket is already
up, so only the per-connection options apply.
""".
-spec serve_opts(listen_opts(), binary() | undefined) -> map().
serve_opts(Opts, Alpn) ->
    Stack = maps:get(stack, Opts),
    Handler = maps:get(handler, Opts),
    Base = conn_base(Opts, Stack, Handler, ssl, Alpn),
    copy_keys(?CONN_KEYS, Opts, Base).

-spec conn_base(
    listen_opts(),
    livery_middleware:stack(),
    livery_middleware:handler(),
    tcp | ssl,
    binary() | undefined
) -> map().
conn_base(Opts, Stack, Handler, Transport, Alpn) ->
    MaxBody = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
    #{
        %% Disable h1's own parser-level body cap and enforce `max_body' in
        %% the translator instead. h1's parser runs upstream of the translate
        %% cap and, on exceed, tears the connection down, which would pre-empt
        %% the graceful 413 the translator delivers via h1's early-response
        %% drain (see abort_body/2). h1's 8 MiB default previously did exactly
        %% that, silently capping any `max_body' above 8 MiB. Requires
        %% erlang_h1 >= 0.7.1, which forwards max_body_size from server opts.
        max_body_size => infinity,
        handler => make_handler_fun(
            Stack, Handler, MaxBody, maps:get(config, Opts, undefined), Transport, Alpn
        )
    }.

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
    term(),
    tcp | ssl,
    binary() | undefined
) ->
    fun(
        (
            h1:connection(),
            h1:stream_id(),
            binary(),
            binary(),
            h1:headers()
        ) -> ok
    ).
make_handler_fun(Stack, Handler, MaxBody, Config, Transport, Alpn) ->
    Ctx = #{
        stack => Stack,
        handler => Handler,
        max_body => MaxBody,
        config => Config,
        transport => Transport,
        alpn => Alpn
    },
    fun(Conn, StreamId, Method, Path, Headers) ->
        serve_request(Conn, StreamId, Method, Path, Headers, Ctx)
    end.

%% Runs in the process h1 spawned for the request, which becomes the
%% request's translator (livery_translator). h1 already sends this
%% stream's events here as `{h1_stream, StreamId, _}', so nothing needs
%% registering.
-spec serve_request(
    h1:connection(), h1:stream_id(), binary(), binary(), h1:headers(), map()
) -> ok.
serve_request(Conn, StreamId, Method, Path, Headers, Ctx) ->
    #{transport := Transport, alpn := Alpn} = Ctx,
    {RawPath, RawQuery} = livery_translator:split_query(Path),
    Stream = {Conn, StreamId, Alpn},
    Req = build_req(Stream, Method, RawPath, Headers, Transport),
    livery_translator:serve(Req, Ctx#{
        adapter => ?MODULE,
        stream => Stream,
        raw_query => RawQuery,
        wire => #{
            tag => h1_stream,
            key => StreamId,
            classify => fun classify/1,
            conn => Conn,
            %% erlang_h1 has no receive flow control yet (no h1:consume/3),
            %% so a slow handler relies on TCP buffers alone.
            credit => none,
            %% Nothing to tell the client: h1's early-response drain reads
            %% and discards the rest of the body before closing, so the
            %% client reads the response instead of a reset.
            on_abandoned => none
        }
    }).

%% The h1 events of this request, in livery_translator's terms.
-spec classify(term()) -> livery_translator:event().
classify({data, Chunk, Fin}) -> {data, Chunk, Fin};
classify({trailers, Trailers}) -> {trailers, Trailers};
classify({stream_reset, Reason}) -> {reset, Reason};
classify(_Event) -> ignore.

-spec build_req(
    stream(),
    binary(),
    binary(),
    h1:headers(),
    tcp | ssl
) -> livery_req:req().
build_req({Conn, _StreamId, _Alpn} = Stream, Method, Path, Headers, Transport) ->
    livery_req:new(#{
        protocol => h1,
        method => Method,
        scheme => scheme(Transport),
        authority => host(Headers),
        path => Path,
        headers => Headers,
        adapter => ?MODULE,
        stream => Stream,
        engine_pid => Conn,
        peer => conn_peer(Conn),
        tls => tls_info(Conn, Transport)
    }).

scheme(ssl) -> <<"https">>;
scheme(_) -> <<"http">>.

%% HTTP/1.1 carries the authority in `Host' (RFC 9112 3.2).
host(Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(K) =:= <<"host">>] of
        [Host | _] -> Host;
        [] -> <<>>
    end.

%% `undefined' marks a plaintext listener, which the WebSocket handoff
%% relies on to pick `ws' over `wss'.
-spec tls_info(h1:connection(), tcp | ssl) -> undefined | livery_tls:info().
tls_info(Conn, ssl) -> livery_tls:info(h1:peercert(Conn));
tls_info(_Conn, _) -> undefined.
