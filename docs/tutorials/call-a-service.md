# Tutorial: Call another service

Almost no service lives alone. Sooner or later yours has to call someone
else: an API for payments, an internal service for users, a webhook out
to a partner. In this tutorial we build a client for one of those, step
by step, and add the resilience you would want in production: a timeout,
retries, a circuit breaker. About 15 minutes.

The client is the outbound twin of Livery's middleware. If you have
written a middleware stack, this will feel familiar: you stack layers
around a request the way you stack them around a handler. Same idea, the
other direction.

## 1. The smallest possible call

Let us start with the least you can write. Build a client, send a GET,
read the answer.

```erlang
Client = livery_client:new(#{base_url => <<"https://api.example.com">>}),
{ok, Resp} = livery_client:get(Client, <<"/health">>),
200 = livery_client:status(Resp),
{full, Body} = livery_client:body(Resp).
```

Three things are happening. `new/1` builds a client value, here with
nothing but a base URL, so we can pass paths instead of full URLs. `get/2`
sends the request and gives back `{ok, Resp}` or `{error, Reason}`. And
the body comes back tagged: `{full, Body}` is the whole thing in memory,
which is what you want for a small JSON reply.

The client is just a value. Build it once, share it, call it from as
many processes as you like.

## 2. Headers and a base URL, set once

Repeating an `authorization` header on every call gets old fast. Put the
defaults on the client and forget about them:

```erlang
Token = <<"s3cret">>,
Auth = iolist_to_binary([<<"Bearer ">>, Token]),
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    headers  => [
        {<<"authorization">>, Auth},
        {<<"accept">>, <<"application/json">>}
    ]
}),
{ok, _} = livery_client:get(Client, <<"/users/42">>).
```

Every request the client sends now carries those two headers. A
per-request header of the same name still wins, so you can override one
without rebuilding the client.

## 3. Turn the response into something useful

A status and a blob of bytes is not what your code wants to work with.
It wants a decoded value, or a clear error. Funnel every call through one
decoder:

```erlang
fetch_user(Client, Id) ->
    Path = <<"/users/", Id/binary>>,
    case livery_client:get(Client, Path) of
        {ok, Resp} -> decode(Resp);
        {error, _} = E -> E
    end.

decode(Resp) ->
    {full, Body} = livery_client:body(Resp),
    case livery_client:status(Resp) of
        S when S >= 200, S < 300 -> {ok, json:decode(Body)};
        404 -> {error, not_found};
        S -> {error, {http, S}}
    end.
```

Notice we build the path into `Path` before the call rather than inline.
That is a small habit worth keeping: it reads better, and a single
`<<"/users/", Id/binary>>` expression in one place is easy to change.

Now `fetch_user/2` returns `{ok, Map}`, `{error, not_found}`, or
`{error, {http, Status}}`, and the caller never sees raw HTTP.

## 4. Add a timeout

The network will, eventually, hang. A call that never returns is worse
than one that fails, so put a ceiling on it. This is your first layer:

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    stack    => [livery_client:timeout(5000)]
}),
case livery_client:get(Client, <<"/slow">>) of
    {ok, Resp}       -> livery_client:status(Resp);
    {error, timeout} -> too_slow
end.
```

`timeout(5000)` gives the whole call five seconds; overrun and it returns
`{error, timeout}` and tears down the connection underneath. A layer is
just an entry in the `stack` list, exactly like a middleware entry.

## 5. Retry the failures worth retrying

Transient failures happen: a `503` while the other side restarts, a
connection reset. For idempotent calls, retrying a few times with backoff
papers over most of them.

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    stack    => [
        livery_client:timeout(5000),
        livery_client:retry(#{max => 3, backoff => {200, 2.0}})
    ]
}),
{ok, _} = livery_client:get(Client, <<"/users/42">>).
```

`retry` retries transport errors and `502/503/504`, up to `max` times,
waiting `200ms` then `400ms` then `800ms` (base `200`, factor `2.0`,
with a little jitter). It only retries idempotent methods unless you opt
in with `retry_non_idempotent => true`, so a `POST` is left alone by
default.

Order matters here. `timeout` sits outside `retry`, so the five seconds
is the budget for all attempts together, not for each one. That is
usually what you want: a hard ceiling on the whole operation.

## 6. Stop hammering a service that is down

Retries are kind to a service having a hiccup. They are cruel to one that
is genuinely down: every caller piles on more load at the worst moment. A
circuit breaker watches the failure rate and, once it crosses a line,
trips, after which calls fail instantly without touching the network
until the service has had time to recover.

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    stack    => [
        livery_client:timeout(5000),
        livery_client:retry(#{max => 3}),
        livery_client:circuit_breaker(#{name => api, window => 20, trip => 0.5})
    ]
}),
case livery_client:get(Client, <<"/users/42">>) of
    {ok, Resp}            -> livery_client:status(Resp);
    {error, circuit_open} -> serve_from_cache();
    {error, _}            -> give_up()
end.
```

Once half of the last 20 calls have failed (`window => 20`,
`trip => 0.5`), the breaker opens and the next call returns
`{error, circuit_open}` straight away. After a cooldown it half-opens to
let one probe through; if that succeeds, it closes again. The `name` is
how breakers are kept apart, so give each upstream its own.

The breaker sits below `retry` on purpose: when it is open, the retries
do not even start.

## 7. Put it together

Here is the whole thing as the module you would actually keep, a small
typed client over one API:

```erlang
-module(users_api).
-export([client/1, fetch/2]).

client(Token) ->
    Auth = iolist_to_binary([<<"Bearer ">>, Token]),
    livery_client:new(#{
        base_url => <<"https://api.example.com">>,
        headers  => [{<<"authorization">>, Auth}],
        stack    => [
            livery_client:timeout(5000),
            livery_client:retry(#{max => 3, backoff => {200, 2.0}}),
            livery_client:circuit_breaker(#{name => users, window => 20, trip => 0.5})
        ]
    }).

fetch(Client, Id) ->
    Path = <<"/users/", Id/binary>>,
    case livery_client:get(Client, Path) of
        {ok, Resp} ->
            {full, Body} = livery_client:body(Resp),
            case livery_client:status(Resp) of
                200 -> {ok, json:decode(Body)};
                404 -> {error, not_found};
                S -> {error, {http, S}}
            end;
        {error, _} = E ->
            E
    end.
```

Call `users_api:client/1` once, hold the value, and call `fetch/2`
wherever you need a user. Timeout, retry, and breaker come along for free
on every call, and the caller only ever sees `{ok, User}` or a clean
error.

## 8. Stream a response to your process

A streamed response with `stream => true` gives you a `{stream, Reader}`
body and `livery_client:read/2`, a blocking pull. That is perfect for a
process whose only job is to drain the body, but it forces a worker that
also wants to react to its own messages, a cancel signal, a progress
tick, into a second process just to run the read loop.

Push mode turns the body around. Set `stream_to` to a pid and the chunks
arrive as messages, so the worker can selectively receive body chunks and
its own control messages side by side:

```erlang
{ok, Resp} = livery_client:request(Client, get, <<"/blob">>, #{
    stream    => true,
    stream_to => self()
}),
{push, Ref} = livery_client:body(Resp),
download(Ref, 0).

download(Ref, Bytes) ->
    receive
        {livery_response, Ref, {status, 200, _Headers}} ->
            download(Ref, Bytes);
        {livery_response, Ref, {chunk, Data}} ->
            Got = Bytes + byte_size(Data),
            io:format("~p bytes~n", [Got]),
            download(Ref, Got);
        {livery_response, Ref, done} ->
            {ok, Bytes};
        {livery_response, Ref, {error, Reason}} ->
            {error, Reason};
        cancel ->
            livery_client:stop_stream(Ref),
            {cancelled, Bytes}
    end.
```

`Ref` is opaque and unique to this request, so a worker running several
downloads tells them apart by matching on it. The messages always arrive
in order: one `{status, Status, Headers}`, then zero or more
`{chunk, Binary}`, then a single `done` (or `{error, Reason}` if the
transfer fails).

The `cancel` clause is the point: a plain message in the same mailbox aborts
the download mid-flight. `livery_client:stop_stream/1` drops the connection,
so a user who quits a multi-gigabyte fetch stops paying for it immediately.

### Backpressure with `flow => manual`

By default chunks are pushed as fast as the wire delivers them. If the
worker writes each chunk somewhere slower than the network, ask for one
chunk at a time with `flow => manual` and pull with
`livery_client:stream_next/1`:

```erlang
{ok, Resp} = livery_client:request(Client, get, <<"/blob">>, #{
    stream    => true,
    stream_to => self(),
    flow      => manual
}),
{push, Ref} = livery_client:body(Resp),
receive
    {livery_response, Ref, {status, _, _}} -> ok
end,
ok = livery_client:stream_next(Ref),   %% pull the first chunk
receive
    {livery_response, Ref, {chunk, First}} -> write(First)
end.
```

No chunk arrives until you call `stream_next/1`, so a slow consumer never
builds an unbounded backlog in its mailbox.

The pull-based `{stream, Reader}` API stays as it was for simple
consumers; reach for push mode when one process needs to interleave body
chunks with its own work.

## Where to go next

- Need to download something large without buffering it? See
  [Make outbound HTTP requests](../guides/make-http-requests.md) for
  streaming responses and request bodies.
- Want to understand why the layers compose the way they do? Read
  [The middleware pipeline](../concepts/middleware-pipeline.md): the
  client is the same model, outbound.
- Fronting a different HTTP client or a mock in tests? The transport is
  a `livery_client_adapter`, the dual of the server
  [adapters](../concepts/adapters.md).
