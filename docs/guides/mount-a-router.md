# How to mount a router on a service

## Problem

Your service has grown past a single endpoint, and you would rather
declare routes than grow one giant handler with a `case` on the path.
You want dispatch by method and path, path parameters bound for you, and
404/405 handled automatically.

## Solution

Compile a router and pass it to `start_service/1` as `router`:

```erlang
Router = livery_router:compile([
    {<<"GET">>,  <<"/">>,         {my_app, index}},
    {<<"GET">>,  <<"/users/:id">>, {my_app, show}},
    {<<"POST">>, <<"/users">>,    {my_app, create}}
]),

{ok, Pid} = livery:start_service(#{
    http       => #{port => 8080},
    middleware => [{livery_request_id, undefined},
                   {livery_access_log, #{}}],
    router     => Router
}).
```

Each route handler is a normal handler - `fun(Req) -> Resp` or
`{Module, Function}` - and receives the request with path
parameters already bound:

```erlang
show(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    livery_resp:json(200, lookup(Id)).
```

`start_service/1` takes **exactly one** of `router` or `handler`.
Use `handler` for a single catch-all; use `router` for dispatch.
The service-level `middleware` stack wraps every route.

## What you get for free

- **404** for an unmatched path.
- **405** with an `Allow` header for a known path on the wrong
  method.
- Path bindings on `livery_req:bindings/1` / `binding/2,3`.

## Per-route middleware

A route's optional `Meta` map (the fourth tuple element) may carry
a `middleware` stack that runs only for that route, inside any
service-level stack:

```erlang
Auth = {my_auth, #{required => true}},
Router = livery_router:compile([
    {<<"GET">>,  <<"/public">>,  {my_app, public}},
    {<<"GET">>,  <<"/private">>, {my_app, private}, #{middleware => [Auth]}}
]).
```

`/private` runs `Auth` before its handler; `/public` does not.
Nesting is service stack (outermost) -> route match -> route stack ->
handler.

## Composing routers

Once a piece of your app is self-contained, it is nicer to keep its
routes together and stitch them in, rather than copy them into one big
list. Three functions let you do that, and they all return a router you
can keep composing.

`merge/2` puts two routers side by side. The later one wins if they
register the same method and path:

```erlang
App = livery_router:compile([{<<"GET">>, <<"/">>, {my_app, index}}]),
Router = livery_router:merge(App, livery_mcp:router()).
```

`nest/3` mounts a sub-router under a prefix. Here the MCP endpoint, which
lives at `/mcp` on its own, ends up at `/ai/mcp`:

```erlang
Router = livery_router:nest(<<"/ai">>, livery_mcp:router(), App).
```

`layer/2` wraps a whole router in a middleware stack, which is the easy
way to put one rule, say auth, over an entire mounted subtree:

```erlang
Admin = livery_router:compile([{<<"GET">>, <<"/admin/stats">>, {my_app, stats}}]),
Guarded = livery_router:nest(<<"/v1">>, livery_router:layer([Auth], Admin), App).
```

Need the flat list back, perhaps to feed `livery_openapi:build/1`?
`livery_router:routes/1` reconstructs it from any router, composed or not.

## Customising 404 / 405

To control the fallbacks, build the handler yourself with
`livery:router_handler/2` and pass it as `handler`:

```erlang
H = livery:router_handler(Router, #{
    not_found          => fun(_R) -> livery_resp:json(404, problem()) end,
    method_not_allowed => fun(_R, _Methods) -> livery_resp:empty(405) end
}),
livery:start_service(#{http => #{port => 8080}, handler => H}).
```

## Using a router without the service

`livery:router_handler/1` returns a plain handler fun, so you can
also use it with a single listener or drive it directly in tests:

```erlang
H = livery:router_handler(Router),
Cap = livery_test_adapter:run([], H,
    #{method => <<"GET">>, path => <<"/users/42">>}).
```

## See also

- Concept: [Routing](../concepts/routing.md)
- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Reference: `livery_router`, `livery`
