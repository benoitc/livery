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

%% Default request-body ceiling (16 MiB); override with `max_body'
%% (`infinity' disables it). See livery_h1 for the rationale.
-define(DEFAULT_MAX_BODY, 16 * 1024 * 1024).

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
    send_full/5,
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
    %% Bind address. An IPv6 8-tuple selects the inet6 family.
    ip => inet:ip_address(),
    %% Bind the IPv6 wildcard (`::') when no explicit `ip' is given.
    inet6 => boolean(),
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    ssl_opts => [ssl:tls_server_option()],
    acceptors => pos_integer(),
    enable_connect_protocol => boolean(),
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
    closed_guard(fun() ->
        case h2:send_response(Conn, StreamId, Status, Headers) of
            ok ->
                case maps:get(end_stream, Opts, false) of
                    true -> h2:send_data(Conn, StreamId, <<>>, true);
                    false -> ok
                end;
            Other ->
                Other
        end
    end).

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) ->
    livery_adapter:send_result().
send_data({Conn, StreamId}, IoData, Opts) ->
    EndStream = maps:get(end_stream, Opts, false),
    closed_guard(fun() -> h2:send_data(Conn, StreamId, iolist_to_binary(IoData), EndStream) end).

%% Coalesced full response: HEADERS + DATA in one h2 call (and one
%% socket write). h2:respond/5 falls back to the granular path itself
%% when it cannot coalesce (oversized headers/body).
-spec send_full(
    stream(),
    100..599,
    [{binary(), binary()}],
    iodata(),
    livery_adapter:send_opts()
) ->
    livery_adapter:send_result().
send_full({Conn, StreamId}, Status, Headers, IoData, _Opts) ->
    closed_guard(fun() ->
        h2:respond(Conn, StreamId, Status, Headers, iolist_to_binary(IoData))
    end).

-spec send_trailers(stream(), [{binary(), binary()}]) ->
    livery_adapter:send_result().
send_trailers({Conn, StreamId}, Trailers) ->
    closed_guard(fun() -> h2:send_trailers(Conn, StreamId, Trailers) end).

%% A send to a connection whose client has gone away exits the underlying
%% `gen_statem:call` (e.g. `{{shutdown, {send_failed, closed}}, _}` or
%% `{noproc, _}`). Map that to `{error, closed}`, the way `gen_tcp:send`
%% already reports it on H1, so `livery:emit/3` treats it as a normal
%% disconnect instead of a handler crash. The crash path would log the
%% response body (carried in the stacktrace), which is both a throughput
%% sink on large responses and a log-hygiene leak.
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
    MaxBody = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
    Base = #{
        transport => Transport,
        handler => make_handler_fun(Stack, Handler, MaxBody, maps:get(config, Opts, undefined))
    },
    copy_keys(
        [
            ip,
            inet6,
            cert,
            key,
            cacerts,
            ssl_opts,
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
    livery_middleware:handler(),
    non_neg_integer() | infinity,
    term()
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
make_handler_fun(Stack, Handler, MaxBody, Config) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        dispatch_request(
            Conn,
            StreamId,
            Method,
            Path,
            Headers,
            Stack,
            Handler,
            MaxBody,
            Config
        )
    end.

-spec dispatch_request(
    h2:connection(),
    h2:stream_id(),
    binary(),
    binary(),
    h2:headers(),
    livery_middleware:stack(),
    livery_middleware:handler(),
    non_neg_integer() | infinity,
    term()
) -> ok.
dispatch_request(Conn, StreamId, Method, Path, Headers, Stack, Handler, MaxBody, Config) ->
    BodyRef = make_ref(),
    DiscRef = make_ref(),
    Reader = livery_body:new(BodyRef),
    {RawPath, RawQuery} = split_query(Path),
    Req = build_req(Conn, StreamId, Method, RawPath, Headers, Reader),
    %% The translator is the disconnect notifier. It is spawned before
    %% the worker (so the req can carry its pid) and given the worker
    %% pid afterwards via {worker, _}, breaking the dependency cycle.
    Translator = spawn(fun() ->
        translator_init(Conn, StreamId, BodyRef, DiscRef, MaxBody)
    end),
    Req1 = Req#livery_req{
        raw_query = RawQuery,
        notifier_pid = Translator,
        disc_ref = DiscRef,
        config = Config
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
            case set_stream_handler(Conn, StreamId, Translator) of
                ok ->
                    ok;
                {ok, _Drained} ->
                    ok;
                %% The client already went away (unknown stream, or the
                %% connection process is shutting down); abandon the
                %% request quietly. The worker's DOWN still balances the
                %% in-flight count.
                {error, _} ->
                    exit(Translator, kill),
                    exit(WorkerPid, kill),
                    ok
            end;
        {error, _} ->
            exit(Translator, kill),
            reject_overload({Conn, StreamId})
    end,
    ok.

%% Register the per-stream translator. Like the send callbacks, a
%% connection that is already shutting down (client gone) exits the
%% gen_statem:call; map it to `{error, closed}` so the caller abandons
%% the request instead of crashing (which would error-log per disconnect).
set_stream_handler(Conn, StreamId, Translator) ->
    closed_guard(fun() ->
        h2:set_stream_handler(Conn, StreamId, Translator, #{drain_buffer => false})
    end).

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
    h2:connection(),
    h2:stream_id(),
    binary(),
    binary(),
    h2:headers(),
    livery_body:reader()
) -> livery_req:req().
build_req(Conn, StreamId, Method, Path, Headers, Reader) ->
    Authority = proplists:get_value(<<":authority">>, Headers, <<>>),
    Scheme = proplists:get_value(<<":scheme">>, Headers, <<"http">>),
    livery_req:new(#{
        protocol => h2,
        method => Method,
        scheme => Scheme,
        authority => Authority,
        path => Path,
        headers => app_headers(Authority, Headers),
        body => {stream, Reader},
        adapter => ?MODULE,
        stream => {Conn, StreamId},
        engine_pid => Conn
    }).

%% h2 (>= 0.10.2) keeps `:authority' and `:scheme' in the handler header
%% list. Drop them from the application-visible headers (they are exposed
%% via livery_req:authority/1 and scheme/1), and synthesize a `host'
%% header from the authority when the client sent none, so host-based
%% routing works even when a compliant HTTP/2 client omits `host'.
-spec app_headers(binary(), h2:headers()) -> h2:headers().
app_headers(Authority, Headers) ->
    Stripped = [H || {Name, _} = H <- Headers, not is_pseudo_header(Name)],
    case {Authority, proplists:is_defined(<<"host">>, Stripped)} of
        {<<>>, _} -> Stripped;
        {_, true} -> Stripped;
        {_, false} -> [{<<"host">>, Authority} | Stripped]
    end.

-spec is_pseudo_header(binary()) -> boolean().
is_pseudo_header(<<":authority">>) -> true;
is_pseudo_header(<<":scheme">>) -> true;
is_pseudo_header(_) -> false.

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

%% Two-phase init: receive the worker pid, then monitor both the worker
%% (for normal completion / handoff) and the connection (for client
%% disconnect, which h2 does not fan out to stream handlers).
-spec translator_init(
    h2:connection(),
    h2:stream_id(),
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
    h2:connection(),
    h2:stream_id(),
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
        {h2, Conn, {data, StreamId, <<>>, true}} ->
            WorkerPid ! {livery_body, BodyRef, eof},
            Loop(Cbs, Fired, Bytes);
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            case livery_body:account(Bytes, Chunk, Max) of
                {ok, Bytes1} ->
                    WorkerPid ! {livery_body, BodyRef, {data, Chunk}},
                    WorkerPid ! {livery_body, BodyRef, eof},
                    Loop(Cbs, Fired, Bytes1);
                _ ->
                    abort_body({Conn, StreamId}, WorkerPid, BodyRef),
                    Loop(Cbs, Fired, aborted)
            end;
        {h2, Conn, {data, StreamId, Chunk, false}} ->
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
        {h2, Conn, {trailers, StreamId, Trailers}} ->
            WorkerPid ! {livery_body, BodyRef, {trailers, Trailers}},
            Loop(Cbs, Fired, Bytes);
        {h2, Conn, {stream_reset, StreamId, Reason}} ->
            WorkerPid ! {livery_body, BodyRef, {reset, Reason}},
            Loop(Cbs, livery_disconnect:fire_once(Fired, WorkerPid, DiscRef, Reason, Cbs), Bytes);
        {'DOWN', CMRef, process, Conn, Reason} ->
            %% Connection closed: client disconnect. Fire, keep looping
            %% (to serve late registrations) until the worker exits.
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
            %% Worker finished (normal request done, or it handed the
            %% stream off to a ws/wt session). Stop translating.
            ok;
        {h2, Conn, _Other} ->
            Loop(Cbs, Fired, Bytes)
    end.

%% Signal the worker that the body exceeded `max_body' and reset the
%% stream so the client stops sending.
-spec abort_body(stream(), pid(), reference()) -> ok.
abort_body(Stream, WorkerPid, BodyRef) ->
    WorkerPid ! {livery_body, BodyRef, {error, body_too_large}},
    _ = reset(Stream, body_too_large),
    ok.
