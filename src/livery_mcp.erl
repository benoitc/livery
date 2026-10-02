-module(livery_mcp).
-moduledoc """
MCP Streamable HTTP handler.

Bridges Livery to the `barrel_mcp` protocol core. `handler/1`
returns a Livery handler that serves the MCP Streamable HTTP
transport (POST requests, GET SSE streams, DELETE session
termination, OPTIONS preflight) by delegating to
`barrel_mcp_http_engine:handle/6`, the transport-neutral MCP
engine. Livery owns the wire (H1/H2/H3, router, middleware); the
engine owns the protocol.

Mount it like any handler, typically at `/mcp`:

```erlang
Router = livery_router:compile([
    {<<"POST">>,   <<"/mcp">>, livery_mcp:handler()},
    {<<"GET">>,    <<"/mcp">>, livery_mcp:handler()},
    {<<"DELETE">>, <<"/mcp">>, livery_mcp:handler()}
]),
livery:start_service(#{https => #{...}, router => Router}).
```

Register tools, resources, and prompts through `barrel_mcp`'s own
API (`barrel_mcp:reg_tool/4` and friends); they live in the shared
`barrel_mcp_registry`. The `barrel_mcp` application must be running;
it is an optional application of Livery, so list it in your own
`applications`.

Options (all optional):

- `auth`: a `barrel_mcp` auth provider config (default: no auth).
  A provider that refuses its options makes `handler/1` raise
  `{auth_provider, Module, Reason}` rather than fail per request.
  `barrel_mcp_auth_bearer` requires an `audience`, and accepts
  `audience => any` only with a `verifier` fun
- `session_enabled`: use `Mcp-Session-Id` sessions (default `true`)
- `allowed_origins`: `any | [binary()]` (default `any`)
- `allow_missing_origin`: accept requests with no `Origin`
  (default `true`)
- `sse_buffer_size`: server-stream buffer (default `256`)
- `sse_keepalive_ms`: how often a quiet SSE stream emits a comment,
  which is also what notices a peer that left without closing
  (default: the `barrel_mcp` `sse_keepalive_ms` app env, else `15000`)
- `max_body_bytes`: request body cap, answered `413` past it
  (default 16 MiB)
- `body_timeout_ms`: how long to wait for each body chunk, answered
  `408` past it (default `60000`)
- `resource_metadata`: OAuth protected-resource-metadata map

The handler delivers the response directly through the adapter and
returns the `taken_over` sentinel, so do not stack response-mutating
middleware after it.
""".

-include("livery.hrl").

-export([handler/0, handler/1]).
-export([router/0, router/1]).

-export_type([opts/0]).

-type opts() :: #{
    auth => map(),
    session_enabled => boolean(),
    allowed_origins => any | [binary()],
    allow_missing_origin => boolean(),
    sse_buffer_size => pos_integer(),
    sse_keepalive_ms => pos_integer(),
    max_body_bytes => pos_integer(),
    body_timeout_ms => pos_integer(),
    resource_metadata => undefined | map()
}.

-type body_limits() :: {Max :: pos_integer(), Timeout :: pos_integer()}.

-define(DEFAULT_MAX_BODY_BYTES, 16 * 1024 * 1024).
-define(DEFAULT_BODY_TIMEOUT, 60000).

-doc "MCP handler with default options.".
-spec handler() -> fun((livery_req:req()) -> livery_resp:resp()).
handler() ->
    handler(#{}).

-doc """
A router for the MCP endpoint at `/mcp`, ready to mount with
`livery_router:nest/3` or `merge/2`.
""".
-spec router() -> livery_router:router().
router() ->
    router(#{}).

-doc "`router/0` with MCP handler options.".
-spec router(opts()) -> livery_router:router().
router(Opts) ->
    Mcp = handler(Opts),
    livery_router:compile([
        {<<"POST">>, <<"/mcp">>, Mcp},
        {<<"GET">>, <<"/mcp">>, Mcp},
        {<<"DELETE">>, <<"/mcp">>, Mcp},
        {<<"OPTIONS">>, <<"/mcp">>, Mcp}
    ]).

-doc "MCP handler built from `Opts` (see the module docs).".
-spec handler(opts()) -> fun((livery_req:req()) -> livery_resp:resp()).
handler(Opts) ->
    EngineConfig = engine_config(Opts),
    Limits = {
        maps:get(max_body_bytes, Opts, ?DEFAULT_MAX_BODY_BYTES),
        maps:get(body_timeout_ms, Opts, ?DEFAULT_BODY_TIMEOUT)
    },
    fun(Req) -> serve(Req, EngineConfig, Limits) end.

%%====================================================================
%% Internals
%%====================================================================

-spec engine_config(opts()) -> barrel_mcp_http_engine:config().
engine_config(Opts) ->
    SessionEnabled = maps:get(session_enabled, Opts, true),
    _ =
        case SessionEnabled of
            true -> barrel_mcp_http_engine:ensure_session_manager();
            false -> ok
        end,
    ResourceMetadata = barrel_mcp_http_engine:normalize_resource_metadata(
        maps:get(resource_metadata, Opts, undefined)
    ),
    AuthConfig0 =
        case barrel_mcp_http_engine:init_auth(maps:get(auth, Opts, #{})) of
            {ok, AuthOk} -> AuthOk;
            {error, Reason} -> error(Reason)
        end,
    AuthConfig = barrel_mcp_http_engine:inject_resource_metadata_url(
        AuthConfig0, ResourceMetadata
    ),
    Config = #{
        mode => stream,
        auth_config => AuthConfig,
        session_enabled => SessionEnabled,
        allowed_origins => maps:get(allowed_origins, Opts, any),
        allow_missing_origin => maps:get(allow_missing_origin, Opts, true),
        sse_buffer_size => maps:get(sse_buffer_size, Opts, 256),
        resource_metadata => ResourceMetadata
    },
    Keepalive = maps:get(
        sse_keepalive_ms,
        Opts,
        application:get_env(barrel_mcp, sse_keepalive_ms, undefined)
    ),
    case Keepalive of
        undefined -> Config;
        Ms -> Config#{sse_keepalive_ms => Ms}
    end.

-spec serve(livery_req:req(), barrel_mcp_http_engine:config(), body_limits()) ->
    livery_resp:resp().
serve(Req, EngineConfig, Limits) ->
    case read_body(Req, Limits) of
        {ok, Body} ->
            Adapter = livery_req:adapter(Req),
            Stream = livery_req:stream(Req),
            ok = barrel_mcp_http_engine:handle(
                livery_req:method(Req),
                livery_req:path(Req),
                livery_req:headers(Req),
                Body,
                responder(Adapter, Stream),
                EngineConfig
            ),
            #livery_resp{status = 200, body = taken_over};
        {error, too_large} ->
            livery_resp:text(413, <<"Request body too large">>);
        {error, timeout} ->
            livery_resp:text(408, <<"Request body timeout">>);
        {error, _} ->
            livery_resp:text(400, <<"Request body incomplete">>)
    end.

-spec read_body(livery_req:req(), body_limits()) ->
    {ok, binary()} | {error, too_large | timeout | term()}.
read_body(Req, {Max, Timeout}) ->
    case livery_req:body(Req) of
        empty ->
            {ok, <<>>};
        {buffered, IoData} ->
            case iolist_size(IoData) > Max of
                true -> {error, too_large};
                false -> {ok, iolist_to_binary(IoData)}
            end;
        {stream, Reader} ->
            case livery_body:read_all(Reader, Timeout, Max) of
                {ok, Bytes, _} -> {ok, Bytes};
                {error, {limit, max_size}, _} -> {error, too_large};
                {error, body_too_large, _} -> {error, too_large};
                {error, Reason, _} -> {error, Reason}
            end
    end.

-spec responder(module(), term()) -> barrel_mcp_http_engine:responder().
responder(Adapter, Stream) ->
    #{
        reply => fun(Status, Headers, Body) ->
            Bin = iolist_to_binary(Body),
            Hdrs = ensure_content_length(Headers, byte_size(Bin)),
            case Adapter:send_headers(Stream, Status, Hdrs, #{end_stream => false}) of
                {error, closed} ->
                    %% Peer gone: drop the body, the stream is already over.
                    ok;
                _ ->
                    _ = Adapter:send_data(Stream, Bin, #{end_stream => true}),
                    ok
            end
        end,
        stream_start => fun(Status, Headers) ->
            _ = Adapter:send_headers(
                Stream,
                Status,
                Headers,
                #{end_stream => false}
            ),
            ok
        end,
        stream_chunk => fun(Data) ->
            Adapter:send_data(
                Stream,
                iolist_to_binary(Data),
                #{end_stream => false}
            )
        end,
        stream_end => fun() ->
            _ = Adapter:send_data(Stream, <<>>, #{end_stream => true}),
            ok
        end
    }.

-spec ensure_content_length([{binary(), binary()}], non_neg_integer()) ->
    [{binary(), binary()}].
ensure_content_length(Headers, Len) ->
    HasFraming = lists:any(
        fun({K, _}) ->
            L = string:lowercase(K),
            L =:= <<"content-length">> orelse L =:= <<"transfer-encoding">>
        end,
        Headers
    ),
    case HasFraming of
        true -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(Len)} | Headers]
    end.
