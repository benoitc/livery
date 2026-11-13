# Tutorial: Call another service

In this tutorial you build an HTTP client for an upstream service
and add what you would want in production to cope with failures: a
timeout, retries, a circuit breaker. It is for you once your own service has
to call someone else, an API for payments, an internal service for
users, a webhook out to a partner. About 15 minutes.

The client works like Livery's middleware, for the requests you send
out. If you have
written a middleware stack, this will feel familiar: you stack layers
around a request the way you stack them around a handler. Same idea, the
other direction.

## 1. The smallest possible call

Start with the least you can write. Build a client, send a GET, read
the answer.

```erlang
Client = livery_client:new(#{base_url => <<"https://api.example.com">>}),
{ok, Resp} = livery_client:get(Client, <<"/health">>),
200 = livery_client:status(Resp),
{full, Body} = livery_client:body(Resp).
```

Three things are happening. `new/1` builds a client value, here with
nothing but a base URL, so you can pass paths instead of full URLs.
`get/2` sends the request and gives back `{ok, Resp}` or
`{error, Reason}`. And the body comes back tagged: `{full, Body}` is the
whole thing in memory, which is what you want for a small JSON reply.

The client is a value. Build it once, share it, call it from as many
processes as you like.

## 2. Headers and a base URL, set once

Repeating an `authorization` header on every call is tedious. Put the
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

A status and some raw bytes are not what your code wants to work with.
It wants a decoded value, or a clear error. Send every answer through one
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

Notice you build the path into `Path` before the call rather than inline.
That is a small habit worth keeping: it reads better, and a single
`<<"/users/", Id/binary>>` expression in one place is easy to change.

Now `fetch_user/2` returns `{ok, Map}`, `{error, not_found}`, or
`{error, {http, Status}}`, and the caller never sees raw HTTP.

## 4. Add a timeout

The network will, eventually, hang. A call that never returns is worse
than one that fails, so put a limit on it. This is your first layer:

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

`timeout(5000)` gives the whole call five seconds; if it takes longer, it
returns `{error, timeout}` and closes the connection the call was using.
A layer is an entry in the `stack` list, like a middleware entry.

## 5. Retry the failures worth retrying

Short-lived failures happen: a `503` while the other side restarts, a
connection reset. For idempotent calls (calls that are safe to repeat),
retrying a few times, waiting a little longer each time, hides most of
them.

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
plus a small random delay). It only retries idempotent methods unless
you turn on `retry_non_idempotent => true`, so a `POST` is left alone by
default.

Order matters here. `timeout` sits outside `retry`, so the five seconds
is the budget for all attempts together, not for each one. That is
usually what you want: a firm limit on the whole operation.

## 6. Stop hammering a service that is down

Retries help a service that has a short problem. They hurt one that is
really down: every caller adds more load at the worst moment. A circuit
breaker watches how many calls fail. Once too many do, it opens, and
calls then fail at once, without touching the network, until the
service has had time to recover.

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

The breaker counts calls in blocks of 20 (`window => 20`). When a block
ends with half or more of its calls failed (`trip => 0.5`), the breaker
opens and the next call returns `{error, circuit_open}` straight away.
Only an error counts as a failure: any response, even a `503`, counts as
a success. After a cooldown it half-opens: it lets one test call
through, and if that call succeeds, it closes again. The `name` is how
breakers are kept apart, so give each upstream its own.

The breaker sits below `retry`, so it counts each attempt on its own.
While it is open, every attempt gets `{error, circuit_open}` at once,
without touching the network, but `retry` still waits between attempts:
the caller sees the error after the last one.

## 7. Put it together

Here is the whole thing as the module you would actually keep, a small
client for one API that returns your own values:

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
wherever you need a user. Timeout, retry, and breaker apply to every
call, and the caller only ever sees `{ok, User}` or a clear error.

## 8. Stream a response to your process

A streamed response with `stream => true` gives you a `{stream, Reader}`
body and `livery_client:read/2`, a call that blocks until the next part
of the body arrives. That suits a process whose only job is to read the
body to the end. But a worker that must also react to its own messages,
such as a cancel signal or a progress tick, then needs a second process
to run the read loop.

Push mode works the other way round: the body comes to you. Set
`stream_to` to a pid and the chunks arrive as messages, so the worker can
receive body chunks and its own control messages side by side:

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

The `cancel` clause is the reason for all this: a plain message in the
same mailbox stops the download halfway. `livery_client:stop_stream/1` drops the connection,
so a user who quits a multi-gigabyte fetch stops paying for it immediately.

### Backpressure with `flow => manual`

By default chunks are sent to you as fast as the network delivers them. If the
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
consumers; use push mode when one process needs to handle body chunks
in between its own work.

## Where to go next

- Need to download something large without buffering it? See
  [Make outbound HTTP requests](../guides/make-http-requests.md) for
  streaming responses and request bodies.
- Want to understand why the layers fit together the way they do? Read
  [The middleware pipeline](../concepts/middleware-pipeline.md): the
  client is the same model, outbound.
- Want to use a different HTTP client, or a mock in tests? The transport
  is a `livery_client_adapter`, the client-side counterpart of the server
  [adapters](../concepts/adapters.md).
