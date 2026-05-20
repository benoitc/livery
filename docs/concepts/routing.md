# Routing

## Shape

`livery_router` is a radix-trie router compiled from a flat list
of `{Method, Path, Handler}` triples:

```erlang
Router = livery_router:compile([
    {<<"GET">>,  <<"/">>,           {hello, index}},
    {<<"GET">>,  <<"/hi/:name">>,   {hello, greet}},
    {<<"GET">>,  <<"/files/*rest">>, {files, serve}},
    {<<"POST">>, <<"/items">>,      {items, create}}
]).
```

`match/3` returns one of:

```erlang
{ok, {hello, greet}, #{<<"name">> => <<"alice">>}, _Meta} =
    livery_router:match(<<"GET">>, <<"/hi/alice">>, Router).

{error, not_found} =
    livery_router:match(<<"GET">>, <<"/nope">>, Router).

{error, {method_not_allowed, [<<"POST">>]}} =
    livery_router:match(<<"GET">>, <<"/items">>, Router).
```

The captured path bindings end up on the request as
`livery_req:bindings/1`.

## Dispatching through a router

You rarely call `match/3` directly. `livery:router_handler/1`
turns a compiled router into a request handler — it matches, sets
the path bindings, invokes the route handler, and produces `404`
for an unknown path or `405` (with an `Allow` header) for a known
path on the wrong method:

```erlang
Handler = livery:router_handler(Router),
%% Handler :: fun((livery_req:req()) -> livery_resp:resp())
```

Give the router straight to the service and it does this for you:

```erlang
livery:start_service(#{
    http   => #{port => 8080},
    router => Router
}).
```

`start_service/1` takes exactly one of `router` or `handler` (a
single catch-all). `router_handler/2` accepts `not_found` and
`method_not_allowed` funs to override the default `404`/`405`
responses.

## Segment kinds

| Pattern | Matches | Binding |
|---|---|---|
| `/users` | exactly `users` | none |
| `/users/:id` | one segment, captured | `#{<<"id">> => Seg}` |
| `/files/*rest` | one or more trailing segments | `#{<<"rest">> => Joined}` |

Static segments are matched first, then `:param` segments, then
`*wildcard`. The trie keeps lookup proportional to path depth, not
route count.

## Method matching

When a path matches a node but no route is registered for the
requested method, `match/3` returns
`{error, {method_not_allowed, Methods}}` where `Methods` is the
list of methods that *are* registered for that path.
`livery:router_handler/1` turns that into a `405` response with an
`Allow` header. A path that matches nothing returns
`{error, not_found}` → `404`.

## Route metadata

Route tuples accept an optional fourth element, a `Meta` map
(`{Method, Path, Handler, Meta}`): operation id, summary, request
schema, response schemas, tags. `match/3` returns it as the
fourth element, and `livery_openapi:build/1` emits an OpenAPI 3.1
document from the same route table.

## Performance

The radix trie does no allocation on lookup besides the bindings
map. Empty bindings reuse a single shared `#{}`. Matching a path
of N segments is O(N) regardless of total route count, with a
constant factor low enough that the router is not a hot path in
production benchmarks.

## See also

- Reference: `livery_router`
- Tutorial: [Your first service](../tutorials/your-first-service.md)
