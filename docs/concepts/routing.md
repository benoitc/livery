# Routing

This page explains how Livery turns a method and a path into a handler,
and the few rules that govern matching. Read it when your service grows
past a handful of endpoints. A router maps a method and a path to a
handler: you give Livery a flat list of routes, it compiles them into a
radix trie once, and from then on each request is matched to its handler
in time proportional to the path depth, not the number of routes.

## When you want a router

**Use a router when** you have more than a couple of endpoints, path
parameters (`/things/:id`), or different methods on the same path. **Skip
it when** the service is a single catch-all (a health probe, a webhook
sink, a proxy); there you can give `start_service/1` a plain `handler`
function instead of a `router`. Most services want the router.

## Shape

`livery_router:compile/1` takes `{Method, Path, Handler}` triples (with
an optional fourth `Meta` element):

```erlang
Router = livery_router:compile([
    {<<"GET">>,  <<"/">>,            {hello, index}},
    {<<"GET">>,  <<"/hi/:name">>,    {hello, greet}},
    {<<"GET">>,  <<"/files/*rest">>, {files, serve}},
    {<<"POST">>, <<"/items">>,       {items, create}}
]).
```

A handler is `{Module, Function}` or a `fun((Req) -> Resp)`. `match/3`
returns one of:

```erlang
{ok, {hello, greet}, #{<<"name">> => <<"alice">>}, _Meta} =
    livery_router:match(<<"GET">>, <<"/hi/alice">>, Router).

{error, not_found} =
    livery_router:match(<<"GET">>, <<"/nope">>, Router).

{error, {method_not_allowed, [<<"POST">>]}} =
    livery_router:match(<<"GET">>, <<"/items">>, Router).
```

## From route to handler

The captured path parameters land on the request as *bindings*, and the
handler reads them by name. The route `{<<"GET">>, <<"/hi/:name">>,
{hello, greet}}` points at this function:

```erlang
greet(Req) ->
    Name = livery_req:binding(<<"name">>, Req),
    livery_resp:text(200, [<<"hello, ">>, Name]).
```

You rarely call `match/3` yourself. `livery:router_handler/1` turns a
compiled router into a request handler: it matches, sets the bindings,
invokes the route handler, and produces `404` for an unknown path or
`405` (with an `Allow` header) for a known path on the wrong method.

```erlang
Handler = livery:router_handler(Router).
%% Handler :: fun((livery_req:req()) -> livery_resp:resp())
```

Give the router straight to the service and it wires that for you:

```erlang
livery:start_service(#{
    http   => #{port => 8080},
    router => Router
}).
```

`start_service/1` takes exactly one of `router` or `handler`.
`livery:router_handler/2` accepts `not_found` and `method_not_allowed`
funs to override the default `404`/`405`.

## Segment kinds

| Pattern | Matches | Binding |
|---|---|---|
| `/users` | exactly `users` | none |
| `/users/:id` | one segment, captured | `#{<<"id">> => Seg}` |
| `/files/*rest` | one or more trailing segments | `#{<<"rest">> => Joined}` |

Static segments match first, then `:param`, then `*wildcard`.

**Use a `:param`** for a resource identifier (`/things/:id`). **Use a
`*wildcard`** when the tail is itself a path: serving static files under
a prefix, or mounting a sub-application. For example
`{<<"GET">>, <<"/assets/*path">>, {my_static, serve}}` hands the joined
remainder to a handler that reads `livery_req:binding(<<"path">>, Req)`
and serves a confined file (see [Serve static files](../guides/serve-static-files.md)).

## Per-route middleware and metadata

The optional fourth element is a `Meta` map: an operation id, summary,
schemas, tags (which `livery_openapi:build/1` turns into an OpenAPI 3.1
document), and a `middleware` key. That key is a stack
`livery:router_handler/1` runs for that route only, nested inside any
service-level stack:

```erlang
{<<"GET">>, <<"/admin">>, {admin, index},
 #{middleware => [{my_api_key, #{keys => [<<"s3cret">>]}}]}}
```

## Composing routers

A router is a value, so you can build it in pieces and join them. This is
how you keep a self-contained feature's routes together and stitch them
in, the way Axum's `nest`/`merge` work:

- `livery_router:merge/2` puts two routers side by side (the later one
  wins on a clash).
- `livery_router:nest/3` mounts a sub-router under a prefix, so
  `livery_mcp:router()` (at `/mcp`) can land at `/ai/mcp`.
- `livery_router:layer/2` wraps a whole router in a middleware stack, the
  easy way to guard a mounted subtree.
- `livery_router:routes/1` reconstructs the flat route list from any
  router, composed or not (the inverse of `compile/1`).

See [Mount a router on a service](../guides/mount-a-router.md).

## Performance

The trie allocates nothing on a lookup besides the bindings map, and
empty bindings reuse one shared `#{}`. Matching an N-segment path is O(N)
regardless of route count, so the router is not a hot path in benchmarks.

## See also

- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Concept: [The middleware pipeline](middleware-pipeline.md)
- Reference: `livery_router`
