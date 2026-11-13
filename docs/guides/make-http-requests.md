# How to make outbound HTTP requests

`livery_client` brings Livery's middleware model to the calls your
service makes: you stack layers around a request the same way you stack
them around a handler. You need it when your service has to call other
services (a payment API, an internal service, a webhook endpoint) and you
want the same protections you put in front of your own handlers, a
timeout, a few retries, a circuit breaker, a limit on concurrent calls,
without writing them again around every call.

## Build a client and call it

Build a client once, keep it, and call it. The layers run from the
outermost in, and every call returns `{ok, Response}` or
`{error, Reason}`, so a failure is a value you match on, not an
exception you have to catch.

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

`post/3`, `put/3`, `delete/2`, `query/3` (the RFC 10008 QUERY method),
and `request/3,4` cover the other methods. With a `base_url` set you pass paths;
without one you pass full URLs.

## A real client, end to end

In practice you wrap the client in a small module: build it once, give
each call a name, and turn the HTTP response into a result your code
understands. Here is a wrapper around a JSON API, the kind of module you
will write.

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

Two habits worth keeping: build a path made of several parts into a
variable before the call (`Path = <<"/invoices/", Id/binary>>`), and keep
one `decode/1` that every call goes through, so status handling lives in
one place.

## The layers

Each function below returns one entry for the stack. Order matters: the
first entry is the outermost, so `timeout` wraps `retry`, which wraps the
rest.

- `timeout(Ms)` returns `{error, timeout}` if the call takes longer than
  `Ms`, and closes the connection the call was using.
- `retry(Opts)` retries transport errors and `502/503/504` with
  exponential backoff. Idempotent methods only unless
  `retry_non_idempotent => true`. `Opts`: `max`, `backoff`
  (`{BaseMs, Factor}`), `statuses`.
- `circuit_breaker(Opts)` opens once the share of failed calls over a
  window passes a threshold. While open, it answers at once with
  `{error, circuit_open}`, until it lets a trial call through to test
  the service again. `Opts`: `name` (required), `window`, `trip`,
  `cooldown`.
- `concurrency(N)` limits how many requests run at once, returning
  `{error, overloaded}` past `N`.

### Ordering, and why

You choose the order the same way as on the server stack. A good
default:

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
the retries too. `concurrency` innermost limits the requests that
actually go out.

### Writing your own layer

Layers have the same shape as server middleware, so a one-off layer can
be a plain fun. This one stamps a request id on every outbound call:

```erlang
StampId = fun(Req, Next) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    Next(livery_client:set_header(<<"x-request-id">>, Id, Req))
end,
Client = livery_client:new(#{base_url => Base, stack => [StampId]}).
```

For the common cases there are shortcuts: `livery_client:before/1`
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

`read_body/1` reads the whole body; to handle each chunk as it arrives,
loop with `read/2`:

```erlang
drain(Reader, Acc) ->
    case livery_client:read(Reader, 5000) of
        {ok, Chunk, Reader1} -> drain(Reader1, [Acc, Chunk]);
        {done, _}            -> {ok, iolist_to_binary(Acc)};
        {error, _} = E       -> E
    end.
```

To stream a request body, pass a fun that returns the next chunk each
time it is called:

```erlang
Body = {stream, fun() -> next_chunk() end},   %% {ok, Chunk, NextFun} | eof
{ok, _} = livery_client:request(Client, post, <<"/upload">>, #{body => Body}).
```

A streamed request body can be sent only once, so it is never retried:
its chunks are gone once sent. Use `retry` on calls whose body is held
in memory.

## Spread load across endpoints

When the service you call has several replicas, swap the single
`base_url` for a `balance` layer over a pool: it picks a replica per
request, avoids the busy or failing ones, and moves to another replica
when one fails.
See [Load-balance outbound requests](load-balance-requests.md).

## Protocols and the transport

The default transport is `livery_client_hackney`, and hackney (4.2 and
later) speaks HTTP/1.1, HTTP/2, and HTTP/3, so one client reaches all
three (TLS, ALPN, connection pooling, IPv6). hackney leaves HTTP/3 off
by default: add `{protocols, [http3, http2, http1]}` to the hackney
options to use it. Set protocol and TLS options with `adapter_opts`:

```erlang
livery_client:new(#{
    base_url     => <<"https://h3.example.com">>,
    adapter_opts => #{hackney => [{ssl_options, [{verify, verify_peer}]}]}
}).
```

The transport is a `livery_client_adapter`, the client-side counterpart
of `livery_adapter`. To use a different HTTP client, implement that
behaviour and pass `adapter => your_module`.

## See also

- Tutorial: [Call another service](../tutorials/call-a-service.md)
- Concept: [The middleware pipeline](../concepts/middleware-pipeline.md)
- Concept: [Adapters](../concepts/adapters.md)
- Reference: `livery_client`, `livery_client_adapter`
