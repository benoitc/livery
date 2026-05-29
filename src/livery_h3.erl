-module(livery_h3).
-moduledoc """
HTTP/3 adapter on top of the `quic` library's `quic_h3` subsystem.

Starts a `quic_h3` server bound to a Livery middleware stack and
handler. For every inbound request the adapter mirrors `livery_h2`'s
pattern:

1. Builds a `#livery_req{}` from the method, path, and headers
   delivered by `quic_h3`.
2. Spawns a `livery_req_proc` worker under `livery_req_sup`.
3. Spawns a translator process that turns
   `{quic_h3, Conn, _}` body and trailer events into the
   `{livery_body, Ref, _}` shape the worker reads via
   `livery_body`.
4. Registers the translator as the stream handler via
   `quic_h3:set_stream_handler/3`.

Response emission goes through `livery:emit/3` and lands on the
adapter callbacks, which call into `quic_h3:send_response/4`,
`quic_h3:send_data/3,4`, and `quic_h3:send_trailers/3`.
""".

-behaviour(livery_adapter).

-include("livery.hrl").

%% Default request-body ceiling (16 MiB); override with `max_body'
%% (`infinity' disables it). See livery_h1 for the rationale.
-define(DEFAULT_MAX_BODY, 16 * 1024 * 1024).

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

-type listener() :: atom().
-type stream() :: {pid(), non_neg_integer()}.

-type listen_opts() :: #{
    name => atom(),
    port => inet:port_number(),
    cert := binary(),
    key := term(),
    settings => map(),
    quic_opts => map(),
    max_body => non_neg_integer() | infinity,
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
""".
-spec start(listen_opts()) -> {ok, listener()} | {error, term()}.
start(Opts) when is_map(Opts) ->
    Name = maps:get(name, Opts, fresh_name()),
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
    Name = fresh_name(),
    start(Name, Opts, StartOpts);
start(Name, Opts, _StartOpts) when is_atom(Name) ->
    Stack = maps:get(stack, Opts),
    Handler = maps:get(handler, Opts),
    Port = maps:get(port, Opts, 0),
    H3Opts = build_h3_opts(Opts, Stack, Handler),
    quic_h3:start_server(Name, Port, H3Opts).

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
send_headers({Conn, StreamId}, Status, Headers, Opts) ->
    case quic_h3:send_response(Conn, StreamId, Status, Headers) of
        ok ->
            case maps:get(end_stream, Opts, false) of
                true -> quic_h3:send_data(Conn, StreamId, <<>>, true);
                false -> ok
            end;
        Other ->
            Other
    end.

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) ->
    livery_adapter:send_result().
send_data({Conn, StreamId}, IoData, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    quic_h3:send_data(Conn, StreamId, iolist_to_binary(IoData), EndStream).

-spec send_trailers(stream(), [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_trailers({Conn, StreamId}, Trailers) ->
    quic_h3:send_trailers(Conn, StreamId, Trailers).

-spec reset(stream(), term()) -> ok.
reset({Conn, StreamId}, _Reason) ->
    _ = quic_h3:cancel(Conn, StreamId),
    ok.

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info({_Conn, _StreamId}) ->
    #{peer => undefined, tls => undefined, alpn => <<"h3">>}.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_Listener) ->
    #{
        trailers => true,
        extended_connect => true,
        datagrams => true,
        capsules => true
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
    Pseudo = connect_pseudo_headers(Req, <<"websocket">>),
    case ws_h3_upgrade:validate_request(Pseudo) of
        {ok, Info} ->
            RespHeaders = drop_status(ws_h3_upgrade:response_headers(Info)),
            case quic_h3:send_response(Conn, StreamId, 200, RespHeaders) of
                ok ->
                    WsReq = #{
                        method => <<"CONNECT">>,
                        path => livery_req:path(Req),
                        headers => livery_req:headers(Req)
                    },
                    ws:accept(
                        livery_ws_h3,
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

drop_status(Headers) ->
    [{N, V} || {N, V} <- Headers, N =/= <<":status">>].

%%====================================================================
%% WebTransport handoff (called by livery_wt:upgrade/3)
%%====================================================================

-doc """
Hand an extended-CONNECT stream to the `webtransport` library
with `transport => h3`.
""".
-spec accept_wt(h3, livery_req:req(), module(), term()) ->
    {ok, pid()} | {error, term()}.
accept_wt(h3, Req, HandlerMod, Opts) ->
    {Conn, StreamId} = livery_req:stream(Req),
    Headers = connect_pseudo_headers(Req, <<"webtransport">>),
    webtransport:accept(Conn, StreamId, Headers, Opts#{
        transport => h3,
        handler => HandlerMod,
        handler_opts => maps:get(handler_opts, Opts, #{})
    }).

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
%% Internals: per-request dispatch
%%====================================================================

-spec fresh_name() -> atom().
fresh_name() ->
    list_to_atom(
        "livery_h3_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic]))
    ).

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
        handler => make_handler_fun(Stack, Handler, MaxBody)
    },
    copy_keys(
        [
            settings,
            quic_opts,
            stream_type_handler,
            h3_datagram_enabled,
            connection_handler,
            %% Number of UDP listener processes. >1 enables SO_REUSEPORT
            %% so the kernel spreads packets across readers, letting H3
            %% use more than one core for transport.
            pool_size
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
            pid(),
            non_neg_integer(),
            binary(),
            binary(),
            [{binary(), binary()}]
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
    pid(),
    non_neg_integer(),
    binary(),
    binary(),
    [{binary(), binary()}],
    livery_middleware:stack(),
    livery_middleware:handler(),
    non_neg_integer() | infinity
) -> ok.
dispatch_request(Conn, StreamId, Method, Path, Headers, Stack, Handler, MaxBody) ->
    BodyRef = make_ref(),
    DiscRef = make_ref(),
    Reader = livery_body:new(BodyRef),
    {RawPath, RawQuery} = split_query(Path),
    Req = build_req(Conn, StreamId, Method, RawPath, Headers, Reader),
    %% Translator is the disconnect notifier; spawned before the worker
    %% so the req carries its pid, and given the worker pid afterwards.
    Translator = spawn(fun() ->
        translator_init(Conn, StreamId, BodyRef, DiscRef, MaxBody)
    end),
    Req1 = Req#livery_req{
        raw_query = RawQuery,
        notifier_pid = Translator,
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
            Translator ! {worker, WorkerPid},
            _ = quic_h3:set_stream_handler(
                Conn,
                StreamId,
                Translator,
                #{drain_buffer => false}
            ),
            ok;
        {error, _} ->
            exit(Translator, kill),
            reject_overload({Conn, StreamId})
    end.

%% No worker slot available (concurrency cap reached): answer 503.
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
    pid(),
    non_neg_integer(),
    binary(),
    binary(),
    [{binary(), binary()}],
    livery_body:reader()
) -> livery_req:req().
build_req(Conn, StreamId, Method, Path, Headers, Reader) ->
    livery_req:new(#{
        protocol => h3,
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
%% Translator: quic_h3 messages -> livery_body protocol
%%====================================================================

%% Two-phase init: receive the worker pid, then monitor the worker and
%% the connection. quic_h3 routes a single-stream reset to the
%% connection owner (not the stream handler), so the reliable client
%% disconnect signal here is the connection 'DOWN'. A single-stream RST
%% without a connection close is not observable in the current quic_h3.
-spec translator_init(
    pid(),
    non_neg_integer(),
    reference(),
    reference(),
    non_neg_integer() | infinity
) -> ok.
translator_init(Conn, StreamId, BodyRef, DiscRef, MaxBody) ->
    receive
        {worker, WorkerPid} ->
            WMRef = erlang:monitor(process, WorkerPid),
            CMRef = erlang:monitor(process, Conn),
            translate_loop(
                Conn, StreamId, BodyRef, DiscRef, WorkerPid, WMRef, CMRef, [], false, MaxBody, 0
            )
    end.

-spec translate_loop(
    pid(),
    non_neg_integer(),
    reference(),
    reference(),
    pid(),
    reference(),
    reference(),
    [fun(() -> term())],
    boolean(),
    non_neg_integer() | infinity,
    non_neg_integer() | aborted
) -> ok.
translate_loop(Conn, StreamId, BodyRef, DiscRef, WorkerPid, WMRef, CMRef, Cbs, Fired, Max, Bytes) ->
    Loop = fun(Cbs1, Fired1, Bytes1) ->
        translate_loop(
            Conn, StreamId, BodyRef, DiscRef, WorkerPid, WMRef, CMRef, Cbs1, Fired1, Max, Bytes1
        )
    end,
    receive
        {quic_h3, Conn, {data, StreamId, <<>>, true}} ->
            WorkerPid ! {livery_body, BodyRef, eof},
            Loop(Cbs, Fired, Bytes);
        {quic_h3, Conn, {data, StreamId, Chunk, true}} ->
            case livery_body:account(Bytes, Chunk, Max) of
                {ok, Bytes1} ->
                    WorkerPid ! {livery_body, BodyRef, {data, Chunk}},
                    WorkerPid ! {livery_body, BodyRef, eof},
                    Loop(Cbs, Fired, Bytes1);
                _ ->
                    abort_body({Conn, StreamId}, WorkerPid, BodyRef),
                    Loop(Cbs, Fired, aborted)
            end;
        {quic_h3, Conn, {data, StreamId, Chunk, false}} ->
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
        {quic_h3, Conn, {trailers, StreamId, Trailers}} ->
            WorkerPid ! {livery_body, BodyRef, {trailers, Trailers}},
            Loop(Cbs, Fired, Bytes);
        {quic_h3, Conn, {stream_reset, StreamId, Reason}} ->
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
            ok;
        {quic_h3, Conn, _Other} ->
            Loop(Cbs, Fired, Bytes)
    end.

%% Signal the worker that the body exceeded `max_body' and reset the
%% stream so the client stops sending.
-spec abort_body(stream(), pid(), reference()) -> ok.
abort_body(Stream, WorkerPid, BodyRef) ->
    WorkerPid ! {livery_body, BodyRef, {error, body_too_large}},
    _ = reset(Stream, body_too_large),
    ok.
