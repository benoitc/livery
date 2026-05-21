-module(livery_h2).
-moduledoc """
HTTP/2 adapter on top of the `h2` library.

Starts an `h2` server bound to a Livery middleware stack and
handler. For every inbound request the adapter:

1. Builds a `#livery_req{}` from the method, path, and headers
   delivered by `h2`.
2. Spawns a `livery_req_proc` worker under `livery_req_sup`.
3. Spawns a small translator process that turns `{h2, Conn, _}`
   body and trailer events into the `{livery_body, Ref, _}`
   shape the worker reads via `livery_body`.
4. Registers the translator as the `h2` stream handler.

Response emission goes through `livery:emit/3` and lands on the
adapter callbacks (`send_headers/4`, `send_data/3`,
`send_trailers/2`, `reset/2`), which call into
`h2:send_response/4`, `h2:send_data/3,4`, and
`h2:send_trailers/3`. `extended_connect` is reported as supported
in `capabilities/1`.
""".

-behaviour(livery_adapter).

-include("livery.hrl").

%% h2:server_opts() declares `cert' and `key' as required map keys,
%% which is wrong for h2c (tcp transport). Suppress the cascading
%% contract-mismatch warning on our entry points until h2's spec
%% relaxes those keys to optional.
-dialyzer({nowarn_function, [start/1, start/3]}).

-export([start/1, accept_ws/4, accept_wt/4]).

-export([
    start/3,
    stop/1,
    send_headers/4,
    send_data/3,
    send_trailers/2,
    reset/2,
    peer_info/1,
    capabilities/1
]).

-export_type([listen_opts/0, listener/0, stream/0]).

-type listener() :: h2:server_ref().
-type stream() :: {h2:connection(), h2:stream_id()}.

-type listen_opts() :: #{
    port => inet:port_number(),
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    acceptors => pos_integer(),
    enable_connect_protocol => boolean(),
    stack := livery_middleware:stack(),
    handler := livery_middleware:handler()
}.

%%====================================================================
%% Public API
%%====================================================================

-doc """
Start a listener with the given options.

`Opts` must include `stack` and `handler`. `port` defaults to 0
(random port). `transport` defaults to `tcp` for h2c; pass `ssl`
plus `cert` and `key` to serve over TLS with ALPN-negotiated h2.
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
    Stack = maps:get(stack, Opts),
    Handler = maps:get(handler, Opts),
    Port = maps:get(port, Opts, 0),
    H2Opts = build_h2_opts(Opts, Stack, Handler),
    h2:start_server(Port, H2Opts).

-spec stop(listener()) -> ok.
stop(Listener) ->
    _ = h2:stop_server(Listener),
    ok.

-spec send_headers(
    stream(),
    100..599,
    [{binary(), binary()}],
    livery_adapter:send_opts()
) ->
    livery_adapter:send_result().
send_headers({Conn, StreamId}, Status, Headers, Opts) ->
    case h2:send_response(Conn, StreamId, Status, Headers) of
        ok ->
            case maps:get(end_stream, Opts, false) of
                true -> h2:send_data(Conn, StreamId, <<>>, true);
                false -> ok
            end;
        Other ->
            Other
    end.

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) ->
    livery_adapter:send_result().
send_data({Conn, StreamId}, IoData, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    h2:send_data(Conn, StreamId, iolist_to_binary(IoData), EndStream).

-spec send_trailers(stream(), [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_trailers({Conn, StreamId}, Trailers) ->
    h2:send_trailers(Conn, StreamId, Trailers).

-spec reset(stream(), term()) -> ok.
reset({Conn, StreamId}, _Reason) ->
    _ = h2:cancel(Conn, StreamId),
    ok.

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info({_Conn, _StreamId}) ->
    %% Future: surface ALPN, peer cert, etc. via h2's connection state.
    #{peer => undefined, tls => undefined, alpn => <<"h2">>}.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_Listener) ->
    #{
        trailers => true,
        extended_connect => true,
        datagrams => false,
        capsules => false
    }.

%%====================================================================
%% WebSocket handoff (RFC 8441 extended CONNECT)
%%====================================================================

-doc """
Accept a WebSocket session on an extended-CONNECT stream.

Validates the RFC 8441 handshake, replies `200` (extended CONNECT
uses 200, not 101), then hands the stream to the `ws` library
driven by the `livery_ws_h2` transport.
""".
-spec accept_ws(stream(), livery_req:req(), module(), term()) ->
    {ok, pid()} | {error, term()}.
accept_ws({Conn, StreamId}, Req, HandlerMod, Opts) ->
    Pseudo = connect_pseudo_headers(Req, <<"websocket">>),
    case ws_h2_upgrade:validate_request(Pseudo) of
        {ok, Info} ->
            RespHeaders = drop_status(ws_h2_upgrade:response_headers(Info)),
            case h2:send_response(Conn, StreamId, 200, RespHeaders) of
                ok ->
                    WsReq = #{
                        method => <<"CONNECT">>,
                        path => livery_req:path(Req),
                        headers => livery_req:headers(Req)
                    },
                    ws:accept(
                        livery_ws_h2,
                        {Conn, StreamId},
                        WsReq,
                        HandlerMod,
                        Opts
                    );
                Err ->
                    {error, {send_response_failed, Err}}
            end;
        {error, Reason} ->
            {error, {bad_request, Reason}}
    end.

%% ws_h2_upgrade:response_headers/1 includes a `:status` pseudo; h2
%% sets the status itself, so strip it before send_response.
drop_status(Headers) ->
    [{N, V} || {N, V} <- Headers, N =/= <<":status">>].

%%====================================================================
%% WebTransport handoff (called by livery_wt:upgrade/3)
%%====================================================================

-doc """
Hand an extended-CONNECT stream to the `webtransport` library.

Reconstructs the CONNECT pseudo-headers from the request value
(the adapter delivers method/path out of band, but
`webtransport:accept/4` expects them inline) and calls
`webtransport:accept/4` with `transport => h2`.
""".
-spec accept_wt(h2, livery_req:req(), module(), term()) ->
    {ok, pid()} | {error, term()}.
accept_wt(h2, Req, HandlerMod, Opts) ->
    {Conn, StreamId} = livery_req:stream(Req),
    Headers = connect_pseudo_headers(Req, <<"webtransport">>),
    webtransport:accept(Conn, StreamId, Headers, Opts#{
        transport => h2,
        handler => HandlerMod,
        handler_opts => maps:get(handler_opts, Opts, #{})
    }).

%%====================================================================
%% Internals: per-request dispatch
%%====================================================================

-spec build_h2_opts(
    listen_opts(),
    livery_middleware:stack(),
    livery_middleware:handler()
) -> map().
build_h2_opts(Opts, Stack, Handler) ->
    Transport = maps:get(transport, Opts, tcp),
    Base = #{
        transport => Transport,
        handler => make_handler_fun(Stack, Handler)
    },
    copy_keys(
        [
            cert,
            key,
            cacerts,
            acceptors,
            settings,
            enable_connect_protocol
        ],
        Opts,
        Base
    ).

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
    livery_middleware:handler()
) ->
    fun(
        (
            h2:connection(),
            h2:stream_id(),
            binary(),
            binary(),
            h2:headers()
        ) -> ok
    ).
make_handler_fun(Stack, Handler) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        dispatch_request(
            Conn,
            StreamId,
            Method,
            Path,
            Headers,
            Stack,
            Handler
        )
    end.

-spec dispatch_request(
    h2:connection(),
    h2:stream_id(),
    binary(),
    binary(),
    h2:headers(),
    livery_middleware:stack(),
    livery_middleware:handler()
) -> ok.
dispatch_request(Conn, StreamId, Method, Path, Headers, Stack, Handler) ->
    BodyRef = make_ref(),
    Reader = livery_body:new(BodyRef),
    {RawPath, RawQuery} = split_query(Path),
    Req = build_req(Conn, StreamId, Method, RawPath, Headers, Reader),
    Req1 = Req#livery_req{raw_query = RawQuery},
    {ok, WorkerPid} = livery_req_sup:start_request(#{
        adapter => ?MODULE,
        stream => {Conn, StreamId},
        req => Req1,
        stack => Stack,
        handler => Handler
    }),
    %% h2 events for this stream go to a per-stream translator. The
    %% translator forwards body/trailer events to the worker in the
    %% livery_body protocol and exits on terminal events. It also
    %% monitors the worker so it cleans up when the worker finishes,
    %% including the WebSocket/WebTransport case where the worker
    %% hands the stream off to another session and exits.
    Translator = spawn(fun() ->
        MRef = erlang:monitor(process, WorkerPid),
        translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef)
    end),
    case
        h2:set_stream_handler(
            Conn,
            StreamId,
            Translator,
            #{drain_buffer => false}
        )
    of
        ok ->
            ok;
        {ok, _Drained} ->
            ok;
        {error, unknown_stream} ->
            exit(Translator, kill),
            exit(WorkerPid, kill),
            ok
    end,
    ok.

-spec build_req(
    h2:connection(),
    h2:stream_id(),
    binary(),
    binary(),
    h2:headers(),
    livery_body:reader()
) -> livery_req:req().
build_req(Conn, StreamId, Method, Path, Headers, Reader) ->
    livery_req:new(#{
        protocol => h2,
        method => Method,
        path => Path,
        headers => Headers,
        body => {stream, Reader},
        adapter => ?MODULE,
        stream => {Conn, StreamId},
        engine_pid => Conn
    }).

-spec split_query(binary()) -> {binary(), binary()}.
split_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [P, Q] -> {P, Q};
        [P] -> {P, <<>>}
    end.

%% Rebuild the pseudo-header proplist the ws/webtransport handshake
%% validators read. The adapter delivers method/path/scheme/authority
%% out of band, so they are re-injected here.
-spec connect_pseudo_headers(livery_req:req(), binary()) ->
    [{binary(), binary()}].
connect_pseudo_headers(Req, Protocol) ->
    Path =
        case livery_req:query(Req) of
            <<>> -> livery_req:path(Req);
            Query -> <<(livery_req:path(Req))/binary, "?", Query/binary>>
        end,
    [
        {<<":method">>, livery_req:method(Req)},
        {<<":protocol">>, Protocol},
        {<<":scheme">>, livery_req:scheme(Req)},
        {<<":authority">>, livery_req:authority(Req)},
        {<<":path">>, Path}
        | livery_req:headers(Req)
    ].

%%====================================================================
%% Translator: h2 messages -> livery_body protocol
%%====================================================================

-spec translate_loop(
    h2:connection(),
    h2:stream_id(),
    reference(),
    pid(),
    reference()
) -> ok.
translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef) ->
    receive
        {h2, Conn, {data, StreamId, <<>>, true}} ->
            WorkerPid ! {livery_body, BodyRef, eof},
            translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef);
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            WorkerPid ! {livery_body, BodyRef, {data, Chunk}},
            WorkerPid ! {livery_body, BodyRef, eof},
            translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef);
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            WorkerPid ! {livery_body, BodyRef, {data, Chunk}},
            translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef);
        {h2, Conn, {trailers, StreamId, Trailers}} ->
            WorkerPid ! {livery_body, BodyRef, {trailers, Trailers}},
            translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef);
        {h2, Conn, {stream_reset, StreamId, Reason}} ->
            WorkerPid ! {livery_body, BodyRef, {reset, Reason}},
            translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef);
        {'DOWN', MRef, process, WorkerPid, _Reason} ->
            %% Worker finished (normal request done, or it handed the
            %% stream off to a ws/wt session). Stop translating.
            ok;
        {h2, Conn, _Other} ->
            translate_loop(Conn, StreamId, BodyRef, WorkerPid, MRef)
    end.
