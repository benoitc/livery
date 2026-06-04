# How to make outbound HTTP requests

## Problem

Your service has to call other services: a payment API, an internal
microservice, a webhook endpoint. You want the same guarantees you put
in front of your own handlers, a timeout, a few retries, a circuit
breaker, a concurrency cap, without hand-rolling them around every call
site. Livery's client is the outbound twin of its middleware: you stack
layers around a request the same way you stack them around a handler.

## Solution

Build a client once, keep it around, and call it. The layers run
outermost-first, and every call returns `{ok, Response}` or
`{error, Reason}`, so failures are values you match on, not exceptions
you chase.

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    headers  => [{<<"authorization">>, <<"Bearer token">>}],
    stack    => [
        livery_client:timeout(5000),
        livery_client:retry(#{max => 3}),
        livery_client:circuit_breaker(#{name => payments}),
        livery_client:concurrency(50)
    ]
}),

case livery_client:get(Client, <<"/users/42">>) of
    {ok, Resp} ->
        200 = livery_client:status(Resp),
        {full, Body} = livery_client:body(Resp),
        handle(Body);
    {error, timeout}      -> slow;
    {error, circuit_open} -> degrade;
    {error, Reason}       -> {failed, Reason}
end.
```

`post/3`, `put/3`, `delete/2`, and `request/3,4` round it out. With a
`base_url` set you pass paths; without one you pass full URLs.

## A real client, end to end

In practice you wrap the client in a small module: build it once, give
each call a name, and turn the HTTP response into a domain result. Here
is a typed wrapper around a JSON API, the shape you will actually write.

```erlang
-module(billing_api).
-export([client/1, get_invoice/2, create_invoice/2]).

%% Build once at startup (or in your supervision tree) and reuse.
client(Token) ->
    Auth = iolist_to_binary([<<"Bearer ">>, Token]),
    livery_client:new(#{
        base_url => <<"https://billing.internal">>,
        headers  => [
            {<<"authorization">>, Auth},
            {<<"accept">>, <<"application/json">>}
        ],
        stack    => [
            livery_client:timeout(5000),
            livery_client:retry(#{max => 3, backoff => {200, 2.0}}),
            livery_client:circuit_breaker(#{name => billing, window => 20, trip => 0.5})
        ]
    }).

get_invoice(Client, Id) ->
    Path = <<"/invoices/", Id/binary>>,
    case livery_client:get(Client, Path) of
        {ok, Resp} -> decode(Resp);
        {error, _} = E -> E
    end.

create_invoice(Client, Invoice) ->
    Body = json:encode(Invoice),
    case livery_client:post(Client, <<"/invoices">>, Body) of
        {ok, Resp} -> decode(Resp);
        {error, _} = E -> E
    end.

%% One place to turn an HTTP response into a domain result.
decode(Resp) ->
    {full, Body} = livery_client:body(Resp),
    case livery_client:status(Resp) of
        S when S >= 200, S < 300 -> {ok, json:decode(Body)};
        404 -> {error, not_found};
        S -> {error, {http, S, Body}}
    end.
```

Two things worth copying: build the multi-segment URL into a variable
before the call (`Path = <<"/invoices/", Id/binary>>`), and keep one
`decode/1` that every verb funnels through, so status handling lives in
one place.

## The layers

Each constructor returns a stack entry; order matters (outermost first,
so `timeout` wraps `retry` wraps the rest).

- `timeout(Ms)` returns `{error, timeout}` if the call overruns, and
  tears down the in-flight connection.
- `retry(Opts)` retries transport errors and `502/503/504` with
  exponential backoff. Idempotent methods only unless
  `retry_non_idempotent => true`. `Opts`: `max`, `backoff`
  (`{BaseMs, Factor}`), `statuses`.
- `circuit_breaker(Opts)` trips once the failure ratio over a window
  crosses a threshold, then fails fast with `{error, circuit_open}`
  until it half-opens to probe. `Opts`: `name` (required), `window`,
  `trip`, `cooldown`.
- `concurrency(N)` caps in-flight requests, returning `{error,
  overloaded}` past `N`.

### Ordering, and why

The order is the same reasoning as the server stack. A useful default:

```erlang
[
    livery_client:timeout(5000),       %% a hard ceiling over everything
    livery_client:retry(#{max => 3}),  %% retries live under the ceiling
    livery_client:circuit_breaker(#{name => api}),
    livery_client:concurrency(50)      %% closest to the wire
].
```

`timeout` outermost means the deadline covers all retries, not each
attempt. `circuit_breaker` below `retry` means a tripped breaker stops
the retries too. `concurrency` innermost caps real connections.

### Writing your own layer

Layers are the same shape as server middleware, so a one-off is just a
fun. This one stamps a request id on every outbound call:

```erlang
StampId = fun(Req, Next) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    Next(livery_client:set_header(<<"x-request-id">>, Id, Req))
end,
Client = livery_client:new(#{base_url => Base, stack => [StampId]}).
```

For the common cases reach for the sugar: `livery_client:before/1`
(transform the request), `after_response/1` (transform the response),
`wrap/1` (catch a downstream crash).

## Streaming

For a large download, ask for a streamed response and read it chunk by
chunk instead of holding it all in memory:

```erlang
{ok, Resp} = livery_client:request(Client, get, <<"/big.csv">>, #{stream => true}),
{stream, Reader} = livery_client:body(Resp),
{ok, All} = livery_client:read_body(Reader).
```

`read_body/1` drains the whole body; to process as it arrives, loop with
`read/2`:

```erlang
drain(Reader, Acc) ->
    case livery_client:read(Reader, 5000) of
        {ok, Chunk, Reader1} -> drain(Reader1, [Acc, Chunk]);
        {done, _}            -> {ok, iolist_to_binary(Acc)};
        {error, _} = E       -> E
    end.
```

To stream a request body, hand a producer that yields chunks:

```erlang
Body = {stream, fun() -> next_chunk() end},   %% {ok, Chunk, NextFun} | eof
{ok, _} = livery_client:request(Client, post, <<"/upload">>, #{body => Body}).
```

A streamed (one-shot) request body is never retried, since its chunks
are already gone once sent; put `retry` on buffered calls.

## Protocols and the transport

The default transport is `livery_client_hackney`, and hackney 4.2 speaks
HTTP/1.1, HTTP/2, and HTTP/3, so one client reaches all three (TLS, ALPN,
pooling, IPv6). Steer protocol and TLS details with `adapter_opts`:

```erlang
livery_client:new(#{
    base_url     => <<"https://h3.example.com">>,
    adapter_opts => #{hackney => [{ssl_options, [{verify, verify_peer}]}]}
}).
```

The transport is a `livery_client_adapter`, the client-side dual of
`livery_adapter`. To front a different client, implement that behaviour
and pass `adapter => your_module`.

## See also

- Tutorial: [Call another service](../tutorials/call-a-service.md)
- Concept: [The middleware pipeline](../concepts/middleware-pipeline.md)
- Concept: [Adapters](../concepts/adapters.md)
- Reference: `livery_client`, `livery_client_adapter`
