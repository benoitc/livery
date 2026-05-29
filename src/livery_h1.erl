-module(livery_h1).
-moduledoc """
HTTP/1.1 adapter on top of the `h1` library.

Starts an `h1` server bound to a Livery middleware stack and
handler. For every inbound request the adapter:

1. Builds a `#livery_req{}` from the method, path, and headers
   delivered by `h1`.
2. Spawns a `livery_req_proc` worker under `livery_req_sup`.
3. Spawns a small translator that turns `{h1, Conn, _}` body and
   trailer events into the `{livery_body, Ref, _}` shape the
   worker reads via `livery_body`.
4. Registers the translator as the `h1` stream handler so the
   engine never blocks on the worker.

Response emission goes through `livery:emit/3` and lands on the
adapter callbacks (`send_headers/4`, `send_data/3`,
`send_trailers/2`, `reset/2`), which in turn call into
`h1:send_response/4`, `h1:send_data/3,4`, and
`h1:send_trailers/3`.
""".

-behaviour(livery_adapter).

-include("livery.hrl").

%% Default request-body ceiling (16 MiB). Bounds how much body the
%% translator forwards into the worker mailbox; override per listener
%% with the `max_body' option (`infinity' disables it).
-define(DEFAULT_MAX_BODY, 16 * 1024 * 1024).

%% Public API
-export([start/1, accept_ws/4]).

%% livery_adapter callbacks
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

-type listener() :: h1:server_ref().
-type stream() :: {h1:connection(), h1:stream_id()}.

-type listen_opts() :: #{
    port => inet:port_number(),
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    acceptors => pos_integer(),
    max_body => non_neg_integer() | infinity,
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
    Stack = maps:get(stack, Opts),
    Handler = maps:get(handler, Opts),
    Port = maps:get(port, Opts, 0),
    H1Opts = build_h1_opts(Opts, Stack, Handler),
    h1:start_server(Port, H1Opts).

-spec stop(listener()) -> ok.
stop(Listener) ->
    _ = h1:stop_server(Listener),
    ok.

-spec send_headers(
    stream(),
    100..599,
    [{binary(), binary()}],
    livery_adapter:send_opts()
) ->
    livery_adapter:send_result().
send_headers({Conn, StreamId}, Status, Headers, Opts) ->
    case h1:send_response(Conn, StreamId, Status, Headers) of
        ok ->
            case maps:get(end_stream, Opts, false) of
                true -> h1:send_data(Conn, StreamId, <<>>, true);
                false -> ok
            end;
        Other ->
            Other
    end.

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) ->
    livery_adapter:send_result().
send_data({Conn, StreamId}, IoData, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    h1:send_data(Conn, StreamId, IoData, EndStream).

-spec send_trailers(stream(), [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_trailers({Conn, StreamId}, Trailers) ->
    h1:send_trailers(Conn, StreamId, Trailers).

-spec reset(stream(), term()) -> ok.
reset({Conn, StreamId}, Reason) ->
    _ = h1:cancel_stream(Conn, StreamId, Reason),
    ok.

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info({_Conn, _StreamId}) ->
    %% The h1 library does not surface the peer address, so it stays
    %% undefined here.
    #{peer => undefined, tls => undefined, alpn => <<"http/1.1">>}.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_Listener) ->
    #{
        trailers => true,
        extended_connect => false,
        datagrams => false,
        capsules => false
    }.

%%====================================================================
%% WebSocket handoff (called by livery_ws:upgrade/3)
%%====================================================================

-doc """
Hand the stream's socket to the `ws` library to run a WebSocket
session.

Validates the RFC 6455 handshake headers, replies 101 via
`h1:accept_upgrade/3`, takes ownership of the raw socket, and
calls `ws:accept/5` with the supplied handler module and opts.

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
accept_ws({Conn, StreamId}, Req, HandlerMod, Opts) ->
    Headers = livery_req:headers(Req),
    case ws_h1_upgrade:validate_request(Headers) of
        {ok, Info} ->
            RespHeaders = ws_h1_upgrade:response_headers(Info),
            case h1:accept_upgrade(Conn, StreamId, RespHeaders) of
                {ok, Socket, _BufferedBytes} ->
                    WsReq = build_ws_req(Req),
                    ws:accept(
                        ws_transport_gen_tcp,
                        Socket,
                        WsReq,
                        HandlerMod,
                        Opts
                    );
                {error, Reason} ->
                    {error, {accept_upgrade_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {bad_request, Reason}}
    end.

-spec build_ws_req(livery_req:req()) -> map().
build_ws_req(Req) ->
    #{
        method => livery_req:method(Req),
        path => livery_req:path(Req),
        query => livery_req:query(Req),
        headers => livery_req:headers(Req)
    }.

%%====================================================================
%% Internals: per-request dispatch
%%====================================================================

-spec build_h1_opts(
    listen_opts(),
    livery_middleware:stack(),
    livery_middleware:handler()
) -> map().
build_h1_opts(Opts, Stack, Handler) ->
    MaxBody = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
    Base = #{
        transport => maps:get(transport, Opts, tcp),
        handler => make_handler_fun(Stack, Handler, MaxBody)
    },
    copy_keys(
        [
            cert,
            key,
            cacerts,
            acceptors,
            handshake_timeout,
            idle_timeout,
            request_timeout,
            max_keepalive_requests
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
    livery_middleware:handler(),
    non_neg_integer() | infinity
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
make_handler_fun(Stack, Handler, MaxBody) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        dispatch_request(
            Conn,
            StreamId,
            Method,
            Path,
            Headers,
            Stack,
            Handler,
            MaxBody
        )
    end.

-spec dispatch_request(
    h1:connection(),
    h1:stream_id(),
    binary(),
    binary(),
    h1:headers(),
    livery_middleware:stack(),
    livery_middleware:handler(),
    non_neg_integer() | infinity
) -> ok.
dispatch_request(Conn, StreamId, Method, Path, Headers, Stack, Handler, MaxBody) ->
    %% This function runs in the per-request worker spawned by
    %% h1_server. Body and trailer events arrive as
    %% `{h1_stream, StreamId, _}' messages in this process's
    %% mailbox.
    BodyRef = make_ref(),
    DiscRef = make_ref(),
    Reader = livery_body:new(BodyRef),
    {RawPath, RawQuery} = split_query(Path),
    Req = build_req(Conn, StreamId, Method, RawPath, Headers, Reader),
    %% The dispatch process (this one) runs the translator loop, so it
    %% is the disconnect notifier the handler registers with.
    Req1 = Req#livery_req{
        raw_query = RawQuery,
        notifier_pid = self(),
        disc_ref = DiscRef
    },
    case
        livery_req_sup:start_request(#{
            adapter => ?MODULE,
            stream => {Conn, StreamId},
            req => Req1,
            stack => Stack,
            handler => Handler
        })
    of
        {ok, WorkerPid} ->
            WMRef = erlang:monitor(process, WorkerPid),
            %% Monitor the h1 connection process too, so a client
            %% disconnect fires even when the handler is not reading the
            %% body or emitting.
            CMRef = erlang:monitor(process, Conn),
            translate_until_done(
                StreamId, BodyRef, DiscRef, Conn, WorkerPid, WMRef, CMRef, [], false, MaxBody, 0
            );
        {error, _} ->
            reject_overload({Conn, StreamId})
    end.

%% No worker slot available (concurrency cap reached): answer 503 and
%% serve the next request instead of crashing the stream handler.
-spec reject_overload(stream()) -> ok.
reject_overload(Stream) ->
    _ = send_headers(
        Stream,
        503,
        [{<<"content-type">>, <<"text/plain; charset=utf-8">>}],
        #{end_stream => true}
    ),
    ok.

-spec build_req(
    h1:connection(),
    h1:stream_id(),
    binary(),
    binary(),
    h1:headers(),
    livery_body:reader()
) -> livery_req:req().
build_req(Conn, StreamId, Method, Path, Headers, Reader) ->
    livery_req:new(#{
        protocol => h1,
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

%%====================================================================
%% Translator: h1 messages -> livery_body protocol
%%====================================================================

%% Run inside the h1-spawned worker. Forward body and trailer events
%% to the livery_req_proc until it exits (the worker is monitored).
%% Returning from this function lets h1_server pump the next request
%% on the same connection.
-spec translate_until_done(
    h1:stream_id(),
    reference(),
    reference(),
    pid(),
    pid(),
    reference(),
    reference(),
    [fun(() -> term())],
    boolean(),
    non_neg_integer() | infinity,
    non_neg_integer() | aborted
) -> ok.
translate_until_done(
    StreamId, BodyRef, DiscRef, Conn, WorkerPid, WMRef, CMRef, Cbs, Fired, Max, Bytes
) ->
    Loop = fun(Cbs1, Fired1, Bytes1) ->
        translate_until_done(
            StreamId, BodyRef, DiscRef, Conn, WorkerPid, WMRef, CMRef, Cbs1, Fired1, Max, Bytes1
        )
    end,
    receive
        {h1_stream, StreamId, {data, <<>>, true}} ->
            WorkerPid ! {livery_body, BodyRef, eof},
            Loop(Cbs, Fired, Bytes);
        {h1_stream, StreamId, {data, Chunk, true}} ->
            case livery_body:account(Bytes, Chunk, Max) of
                {ok, Bytes1} ->
                    WorkerPid ! {livery_body, BodyRef, {data, Chunk}},
                    WorkerPid ! {livery_body, BodyRef, eof},
                    Loop(Cbs, Fired, Bytes1);
                _ ->
                    abort_body({Conn, StreamId}, WorkerPid, BodyRef),
                    Loop(Cbs, Fired, aborted)
            end;
        {h1_stream, StreamId, {data, Chunk, false}} ->
            case livery_body:account(Bytes, Chunk, Max) of
                {ok, Bytes1} ->
                    WorkerPid ! {livery_body, BodyRef, {data, Chunk}},
                    Loop(Cbs, Fired, Bytes1);
                aborted ->
                    Loop(Cbs, Fired, aborted);
                over ->
                    abort_body({Conn, StreamId}, WorkerPid, BodyRef),
                    Loop(Cbs, Fired, aborted)
            end;
        {h1_stream, StreamId, {trailers, Headers}} ->
            WorkerPid ! {livery_body, BodyRef, {trailers, Headers}},
            Loop(Cbs, Fired, Bytes);
        {h1_stream, StreamId, {stream_reset, Reason}} ->
            WorkerPid ! {livery_body, BodyRef, {reset, Reason}},
            Loop(Cbs, livery_disconnect:fire_once(Fired, WorkerPid, DiscRef, Reason, Cbs), Bytes);
        {'DOWN', CMRef, process, Conn, Reason} ->
            Loop(
                Cbs,
                livery_disconnect:fire_once(
                    Fired, WorkerPid, DiscRef, {connection_closed, Reason}, Cbs
                ),
                Bytes
            );
        {livery_on_disconnect, DiscRef, Fun} ->
            Loop(livery_disconnect:register(Fired, Fun, Cbs), Fired, Bytes);
        {'DOWN', WMRef, process, WorkerPid, _Reason} ->
            ok
    end.

%% Signal the worker that the body exceeded `max_body' and cut the
%% stream so the client stops sending. Bounds the worker mailbox.
-spec abort_body(stream(), pid(), reference()) -> ok.
abort_body(Stream, WorkerPid, BodyRef) ->
    WorkerPid ! {livery_body, BodyRef, {error, body_too_large}},
    _ = reset(Stream, body_too_large),
    ok.
