# How to serve A2A agents

`livery_a2a` mounts an A2A (Agent2Agent protocol) agent built with
`barrel_a2a` on a Livery service: the agent card (the JSON document
that describes your agent), the JSON-RPC and HTTP+JSON endpoints, and
their SSE streams all go through your router, middleware and listeners.
You need it when other agents should reach yours through the same
service that serves the rest of your routes, with Livery middleware
in front.

## Add the dependency

`barrel_a2a` is an optional application of Livery: Livery does not
fetch it for you. Add it to your own `rebar.config` and list it in your
`.app.src`:

```erlang
{deps, [livery, {barrel_a2a, "~> 0.3.0"}]}.
```

```erlang
{applications, [kernel, stdlib, livery, barrel_a2a]}
```

## Mount an agent

Start the barrel_a2a server without its own listener and hand its
routes to the router. `url` is the public base URL the card lists in
`supportedInterfaces`:

```erlang
Card = barrel_a2a_agent_card:new(#{
    name => <<"Echo">>,
    description => <<"Echoes text back">>,
    version => <<"1.0.0">>,
    skills => [#{id => <<"echo">>, name => <<"Echo">>, description => <<"Echo">>}]
}),
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    listen => false,
    url => <<"https://agent.example">>
}),
livery:start_service(#{
    https  => #{port => 8443, cert => Cert, key => Key},
    router => livery_a2a:router(Server)
}).
```

`my_agent` implements `barrel_a2a_handler`; see the barrel_a2a guides
for the handler API. With the defaults, the routes are
`/.well-known/agent-card.json` and everything under `/a2a`.

## Merge with your routes

`router/1` returns a compiled router. Merge it into yours:

```erlang
App = livery_router:compile([
    {<<"GET">>, <<"/health">>, fun(_) -> livery_resp:text(200, <<"ok">>) end}
]),
Router = livery_router:merge(App, livery_a2a:router(Server)).
```

Every path under the agent's prefix goes to the engine (the barrel_a2a
code that handles the requests), so a path there that the agent does
not serve gets the engine's 404, not yours. A route of your own under
the prefix still wins, since the router prefers a literal segment to a
wildcard:

```erlang
livery_router:merge(
    livery_router:compile([{<<"GET">>, <<"/a2a/status">>, Status}]),
    livery_a2a:router(Server)
).
```

## Authenticate with Livery middleware

Put any auth middleware in front of the A2A router. When it sets
`meta(user)`, `livery_a2a` passes the value to the engine as the
principal (the authenticated caller) and barrel_a2a's own auth hook is
skipped; the handler
reads it with `barrel_a2a_ctx:principal/1`:

```erlang
Stack = [{livery_auth_bearer, #{jwks_uri => <<"https://issuer.example/jwks">>}}],
Router = livery_router:layer(Stack, livery_a2a:router(Server)).
```

An anonymous request gets Livery's `401`, including on the card.
Clients built with `barrel_a2a_client` send their credentials on the
card fetch too:

```erlang
{ok, Agent} = barrel_a2a_client:connect(<<"https://agent.example">>, #{
    auth => {bearer, Token}
}).
```

To keep the card public, leave the stack off and use barrel_a2a's
`auth` option on the server instead; it already leaves the card open.

## Nest under a prefix

The engine matches full paths, so give it the full public prefix as
`base_path`, both on the server (so the card lists it) and on the
router:

```erlang
Base = <<"/agents/echo/a2a">>,
{ok, Server} = barrel_a2a_server:start(Card, #{
    handler => my_agent,
    listen => false,
    url => <<"https://agent.example">>,
    base_path => Base
}),
Router = livery_router:merge(App, livery_a2a:router(Server, #{base_path => Base})).
```

`livery_router:nest/2` does not apply here: it would move the
well-known card path under the prefix too, and the engine would not
recognise the prefixed paths.

## Serve the card at the well-known path

The card is served at `/.well-known/agent-card.json` by default,
with an `ETag` and a `Cache-Control` max-age. Change the path or the
cache lifetime through `router/2`:

```erlang
livery_a2a:router(Server, #{
    card_path => <<"/agent-card.json">>,
    card_cache_max_age => 60
}).
```

A client then needs the same `card_path` in
`barrel_a2a_client:connect/2`.

## Options

`router/2` accepts the engine options of
`barrel_a2a_server:engine_config/2`, checked once when the router is
built:

| Key | Default | Meaning |
|---|---|---|
| `base_path` | `<<"/a2a">>` | Prefix of the JSON-RPC and REST routes |
| `card_path` | `<<"/.well-known/agent-card.json">>` | Where the card is served |
| `card_cache_max_age` | `3600` | `Cache-Control` max-age of the card |
| `keepalive_ms` | `15000` | SSE keepalive comment interval |
| `hsts` | `false` | Add `Strict-Transport-Security` |
| `tenant` | `undefined` | Also serve tenant-prefixed REST routes |

A bad value raises `{invalid_engine_option, Key, Value}` from
`router/2`.

Two more options limit the request body before the engine sees it, the
same ones `livery_mcp` takes:

| Key | Default | Meaning |
|---|---|---|
| `max_body_bytes` | 16 MiB | Largest body accepted; `413` past it |
| `body_timeout_ms` | `60000` | Longest wait for one body chunk; `408` past it |

```erlang
livery_a2a:router(Server, #{max_body_bytes => 1048576, body_timeout_ms => 15000})
```

A body over the listener's own `max_body` also gets `413`, and a body
cut off in the middle gets `400`.

## Notes

- The handler writes the response straight to the connection and
  returns the `taken_over` sentinel, so do not stack middleware that
  changes the response after it.
- SSE streams run in the request worker. When the client goes away,
  the worker sees Livery's disconnect message and the engine loop
  ends; the task itself keeps running to completion.
- Every 404 and 405 inside the mount comes from the engine, as an A2A
  error object rather than Livery's plain text. An unknown custom verb
  such as `POST /a2a/v1/tasks/abc:frobnicate` is a 404, and a known
  one reached with the wrong method is a 405 whose `Allow` names the
  method that serves the verb. Paths outside the mount stay yours.
- The same routes serve all three protocols; mount them once on a
  service that runs several protocols and A2A works over H2 and H3
  too.

## See also

- Reference: `livery_a2a`, and the `barrel_a2a` docs for the handler
  behaviour, tasks, push notifications, and the client.
- Concept: [Routing](../concepts/routing.md)
