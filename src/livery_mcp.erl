-module(livery_mcp).
-moduledoc """
MCP Streamable HTTP handler.

Bridges Livery to the `barrel_mcp` protocol core. `handler/1`
returns a Livery handler that serves the MCP Streamable HTTP
transport (POST requests, GET SSE streams, DELETE session
termination, OPTIONS preflight) by delegating to
`barrel_mcp_http_engine:handle/6` — the transport-neutral MCP
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
`barrel_mcp_registry`. The `barrel_mcp` application must be running
(it is started transitively as a Livery dependency).

Options (all optional):

- `auth` — a `barrel_mcp` auth provider config (default: no auth)
- `session_enabled` — use `Mcp-Session-Id` sessions (default `true`)
- `allowed_origins` — `any | [binary()]` (default `any`)
- `allow_missing_origin` — accept requests with no `Origin`
  (default `true`)
- `sse_buffer_size` — server-stream buffer (default `256`)
- `resource_metadata` — OAuth protected-resource-metadata map

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
    resource_metadata => undefined | map()
}.

-define(BODY_TIMEOUT, 30000).

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
    fun(Req) -> serve(Req, EngineConfig) end.

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
    AuthConfig0 = barrel_mcp_http_engine:init_auth(maps:get(auth, Opts, #{})),
    AuthConfig = barrel_mcp_http_engine:inject_resource_metadata_url(
        AuthConfig0, ResourceMetadata
    ),
    #{
        mode => stream,
        auth_config => AuthConfig,
        session_enabled => SessionEnabled,
        allowed_origins => maps:get(allowed_origins, Opts, any),
        allow_missing_origin => maps:get(allow_missing_origin, Opts, true),
        sse_buffer_size => maps:get(sse_buffer_size, Opts, 256),
        resource_metadata => ResourceMetadata
    }.

-spec serve(livery_req:req(), barrel_mcp_http_engine:config()) ->
    livery_resp:resp().
serve(Req, EngineConfig) ->
    Adapter = livery_req:adapter(Req),
    Stream = livery_req:stream(Req),
    Responder = responder(Adapter, Stream),
    ok = barrel_mcp_http_engine:handle(
        livery_req:method(Req),
        livery_req:path(Req),
        livery_req:headers(Req),
        read_body(Req),
        Responder,
        EngineConfig
    ),
    #livery_resp{status = 200, body = taken_over}.

-spec read_body(livery_req:req()) -> binary().
read_body(Req) ->
    case livery_req:body(Req) of
        empty ->
            <<>>;
        {buffered, IoData} ->
            iolist_to_binary(IoData);
        {stream, Reader} ->
            case livery_body:read_all(Reader, ?BODY_TIMEOUT) of
                {ok, Bytes, _} -> Bytes;
                _ -> <<>>
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
