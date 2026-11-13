-module(livery_a2a).
-moduledoc """
A2A HTTP bridge.

Serves an A2A agent (agent card, JSON-RPC and HTTP+JSON bindings, SSE
streams) from a Livery service by delegating to
`barrel_a2a_http_engine:handle/6`, the transport-neutral A2A engine.
Livery owns the wire (H1/H2/H3, router, middleware); the engine owns
the protocol.

Start the agent without a listener, then mount its routes:

```erlang
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    listen => false,
    url => <<"https://agent.example">>
}),
livery:start_service(#{
    https => #{...},
    router => livery_a2a:router(Server)
}).
```

`router/2` takes the engine options `barrel_a2a_server:engine_config/2`
accepts (`base_path`, `card_path`, `card_cache_max_age`, `hsts`,
`keepalive_ms`, `tenant`). They are validated once when the router is
built; a bad value raises `{invalid_engine_option, Key, Value}`.

Two more options bound the request body before the engine sees it:

- `max_body_bytes`: the largest body accepted, answered `413` past it
  (default 16 MiB). The listener's own `max_body` is also answered `413`.
- `body_timeout_ms`: how long to wait for each body chunk, answered
  `408` past it (default `60000`).

A body that ends any other way is answered `400`.

Every route is mounted for any method, and the agent's whole subtree
behind one wildcard, so the engine answers every 404 and 405 inside
the mount as an A2A error object, exactly as it does behind its own
listener: an unknown custom verb is its 404, and a known one reached
with the wrong method its 405 naming the method that serves it. Paths
outside the mount stay livery's. A route of your own under the prefix
still wins, since the router prefers a literal segment to a wildcard.

The engine matches absolute paths, so mounting under a prefix means
passing that prefix as `base_path` (to `barrel_a2a_server:start/2` so
the card advertises it, and to `router/2`) and merging the result into
your router with `livery_router:merge/2`. `livery_router:nest/2` does
not apply.

Authentication can come from Livery middleware: when
`livery_auth_bearer` (or any middleware) sets `meta(user)`, the value
is passed to the engine as `principal` and the barrel_a2a auth hook is
skipped. Without it, the server's own `auth` option applies.

The handler delivers the response directly through the adapter and
returns the `taken_over` sentinel, so do not stack response-mutating
middleware after it.
""".

-export([handler/1, handler/2]).
-export([router/1, router/2]).

-define(BODY_OPTS, [max_body_bytes, body_timeout_ms]).

-doc "A router over the agent's routes, with default engine options.".
-spec router(pid()) -> livery_router:router().
router(Server) ->
    router(Server, #{}).

-doc "`router/1` with engine and body options (see the module docs).".
-spec router(pid(), map()) -> livery_router:router().
router(Server, Opts) ->
    %% engine_config/2 keeps keys it does not know, so the body options
    %% are taken out before they reach the engine.
    Config = barrel_a2a_server:engine_config(Server, maps:without(?BODY_OPTS, Opts)),
    Handler = handler(Config, maps:with(?BODY_OPTS, Opts)),
    Base = maps:get(base_path, Config),
    %% Any route the engine declares outside the agent's own subtree,
    %% the card by default. Everything under the subtree is covered by
    %% the wildcard below.
    Outside = lists:usort([
        Pattern
     || {_Method, Pattern} <- barrel_a2a_http_engine:routes(Config),
        not under(Base, Pattern)
    ]),
    livery_router:compile([
        {'_', <<Base/binary, "/*a2a">>, Handler}
        | [{'_', Pattern, Handler} || Pattern <- Outside]
    ]).

%% Whether an engine route falls inside the agent's subtree. The base
%% is joined the way the engine joins it, so a base livery accepts is
%% exactly a base the engine accepts.
-spec under(binary(), binary()) -> boolean().
under(Base, Pattern) ->
    Size = byte_size(Base),
    case Pattern of
        <<Prefix:Size/binary, Rest/binary>> when Prefix =:= Base ->
            case Rest of
                <<>> -> true;
                <<$/, _/binary>> -> true;
                _ -> false
            end;
        _ ->
            false
    end.

-doc """
A handler over an engine configuration from
`barrel_a2a_server:engine_config/2`.
""".
-spec handler(barrel_a2a_http_engine:config()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
handler(Config) ->
    handler(Config, #{}).

-doc "`handler/1` with the `max_body_bytes` and `body_timeout_ms` options.".
-spec handler(barrel_a2a_http_engine:config(), map()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
handler(Config, Opts) ->
    Limits = livery_engine_bridge:limits(Opts),
    fun(Req) -> serve(Req, Config, Limits) end.

%%====================================================================
%% Internals
%%====================================================================

-spec serve(
    livery_req:req(), barrel_a2a_http_engine:config(), livery_engine_bridge:limits()
) ->
    livery_resp:resp().
serve(Req, Config, Limits) ->
    Disconnected = #{
        disconnected => fun
            ({livery_disconnect, _, _}) -> true;
            (_) -> false
        end
    },
    livery_engine_bridge:serve(Req, Limits, Disconnected, fun(Body, Responder) ->
        barrel_a2a_http_engine:handle(
            livery_req:method(Req),
            raw_path(Req),
            livery_req:headers(Req),
            Body,
            Responder,
            Config#{
                principal => livery_ext:user(Req, undefined),
                peer => livery_req:peer(Req)
            }
        )
    end).

-spec raw_path(livery_req:req()) -> binary().
raw_path(Req) ->
    Path = livery_req:path(Req),
    case livery_req:query(Req) of
        <<>> -> Path;
        Query -> <<Path/binary, "?", Query/binary>>
    end.
