# How to mount a router on a service

A router sends each request to a handler by method and path, extracts
path parameters for you, and answers 404 and 405 on its own. You need it
once your service has more than one endpoint and you would rather list
routes than grow one large handler with a `case` on the path.

## Compile and mount a router

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

Each route handler is a normal handler, `fun(Req) -> Resp` or
`{Module, Function}`, and receives the request with path parameters
already bound:

```erlang
show(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    livery_resp:json(200, lookup(Id)).
```

`start_service/1` takes **exactly one** of `router` or `handler`. Use
`handler` for one handler that takes every request; use `router` to pick
a handler per route. The service-level `middleware` stack wraps every
route.

## What you get for free

- **404** for an unmatched path.
- **405** with an `Allow` header for a known path on the wrong method.
- Path bindings on `livery_req:bindings/1` / `binding/2,3`.

## Add per-route middleware

A route's optional `Meta` map (the fourth tuple element) may carry a
`middleware` stack that runs only for that route, inside any
service-level stack:

```erlang
Auth = {my_auth, #{required => true}},
Router = livery_router:compile([
    {<<"GET">>,  <<"/public">>,  {my_app, public}},
    {<<"GET">>,  <<"/private">>, {my_app, private}, #{middleware => [Auth]}}
]).
```

`/private` runs `Auth` before its handler; `/public` does not. The order
is: service stack (outermost), then route matching, then the route
stack, then the handler.

## Compose routers

Once a part of your app stands on its own, it is easier to keep its
routes together and add them as a block than to copy them into one big
list. Three functions do this, and each returns a router you can combine
again.

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
way to apply one rule, say auth, to every route under a prefix:

```erlang
Admin = livery_router:compile([{<<"GET">>, <<"/admin/stats">>, {my_app, stats}}]),
Guarded = livery_router:nest(<<"/v1">>, livery_router:layer([Auth], Admin), App).
```

Need the flat list back, for example to pass it to
`livery_openapi:build/1`? `livery_router:routes/1` rebuilds it from any
router, combined or not.

## Customise 404 / 405

To control the fallbacks, build the handler yourself with
`livery:router_handler/2` and pass it as `handler`:

```erlang
H = livery:router_handler(Router, #{
    not_found          => fun(_R) -> livery_resp:json(404, problem()) end,
    method_not_allowed => fun(_R, _Methods) -> livery_resp:empty(405) end
}),
livery:start_service(#{http => #{port => 8080}, handler => H}).
```

## Use a router without the service

`livery:router_handler/1` returns a plain handler fun, so you can also
use it with a single listener or call it directly in tests:

```erlang
H = livery:router_handler(Router),
Cap = livery_test_adapter:run([], H,
    #{method => <<"GET">>, path => <<"/users/42">>}).
```

## See also

- Concept: [Routing](../concepts/routing.md)
- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Reference: `livery_router`, `livery`
