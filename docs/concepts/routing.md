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

`match/3` returns `{match, Handler, Bindings}` or `nomatch`:

```erlang
{match, {hello, greet}, #{<<"name">> => <<"alice">>}} =
    livery_router:match(<<"GET">>, <<"/hi/alice">>, Router).
```

The path bindings end up on the request as
`livery_req:bindings/1`.

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

A method that does not have a route registered at the matched node
returns `nomatch`. There is no per-method 405 in the router today;
your application can return `405 Method Not Allowed` from a
fallback handler if needed.

## Route metadata (Phase 9)

When OpenAPI lands, route triples accept an optional `Meta` map:
operation id, summary, request schema, response schemas, tags.
`livery_openapi:build/1` emits the document from the same route
table.

## Performance

The radix trie does no allocation on lookup besides the bindings
map. Empty bindings reuse a single shared `#{}`. Matching a path
of N segments is O(N) regardless of total route count, with a
constant factor low enough that the router is not a hot path in
production benchmarks.

## See also

- Reference: `livery_router`
- Tutorial: [Your first service](../tutorials/your-first-service.md)
