# How to mount a router on a service

## Problem

Your service has grown past a single endpoint. Now you have a handful
of routes, and stuffing them all into one giant handler that switches
on method and path is no fun. You want the service to do the
dispatching for you - by method and path, with path parameters bound
automatically and sensible 404/405 responses handled out of the box.

## Solution

Compile a router and hand it to `start_service/1` under the `router`
key:

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

Each route handler is just a normal handler - a `fun(Req) -> Resp` or
a `{Module, Function}` pair - and it receives the request with the
path parameters already bound for you:

```erlang
show(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    livery_resp:json(200, lookup(Id)).
```

A small rule to keep in mind: `start_service/1` takes **exactly one**
of `router` or `handler`. Reach for `handler` when you genuinely want
a single catch-all, and `router` whenever you want dispatch. Either
way, the service-level `middleware` stack wraps every route.

## What you get for free

- **404** for an unmatched path.
- **405** with an `Allow` header for a known path on the wrong
  method.
- Path bindings on `livery_req:bindings/1` / `binding/2,3`.

## Per-route middleware

Not every route needs the same treatment. A route's optional `Meta`
map (the fourth element of the tuple) can carry its own `middleware`
stack that runs for that route alone, nested inside any service-level
stack:

```erlang
Auth = {my_auth, #{required => true}},
Router = livery_router:compile([
    {<<"GET">>,  <<"/public">>,  {my_app, public}},
    {<<"GET">>,  <<"/private">>, {my_app, private}, #{middleware => [Auth]}}
]).
```

So `/private` runs `Auth` before its handler, and `/public` skips it
entirely. The nesting, from the outside in, is: service stack → route
match → route stack → handler.

## Customising 404 / 405

The default 404 and 405 are fine for most services, but when you want
your own (a problem+json body, say), build the handler yourself with
`livery:router_handler/2` and pass it as `handler`:

```erlang
H = livery:router_handler(Router, #{
    not_found          => fun(_R) -> livery_resp:json(404, problem()) end,
    method_not_allowed => fun(_R, _Methods) -> livery_resp:empty(405) end
}),
livery:start_service(#{http => #{port => 8080}, handler => H}).
```

## Using a router without the service

A router is not tied to a full service. `livery:router_handler/1`
gives you back a plain handler fun, which you can wire into a single
listener or drive straight from a test:

```erlang
H = livery:router_handler(Router),
Cap = livery_test_adapter:run([], H,
    #{method => <<"GET">>, path => <<"/users/42">>}).
```

## See also

- Concept: [Routing](../concepts/routing.md)
- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Reference: `livery_router`, `livery`
