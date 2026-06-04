# How to limit concurrency (load-shedding)

## Problem

A traffic spike arrives and suddenly there are more in-flight
requests than your workers - or a downstream model - can possibly
handle. Left alone, everything slows down together and the whole
service falls over. The healthier move is to cap concurrency and turn
the overflow away with a quick `503`, so the requests you do accept
stay fast.

## Solution

Add `livery_concurrency` to the stack, built through the `limiter/1`
factory (it creates the shared counter once, up front):

```erlang
Stack = [
    {livery_concurrency, livery_concurrency:limiter(1000)}
    %% ... handler runs only while fewer than 1000 requests are in flight
].
```

As long as you are at or under the limit, the request sails through.
Go over, and it is shed right away with `503 Service Unavailable` and
your handler is never even called. The counter is a lock-free
`atomics` cell shared across request processes - no extra process to
babysit, no lock to contend on.

## Options

```erlang
livery_concurrency:limiter(500, #{
    status => 429,                 %% default 503
    body => <<"slow down">>,       %% default <<"service unavailable">>
    retry_after => 5               %% adds Retry-After: 5 (seconds, or a binary)
})
```

## Global vs per-route

Each call to `limiter/1,2` returns a State carrying its own counter,
which means every limiter is independent. Use that to your advantage:

```erlang
%% one global limit in the service stack
ServiceStack = [{livery_concurrency, livery_concurrency:limiter(2000)}],

%% a tighter limit on an expensive route group
InferStack = [{livery_concurrency, livery_concurrency:limiter(8)} | Common].
```

## Scope and caveats

- A slot is held from admission until the handler RETURNS its
  response. Body streaming happens after that, outside the middleware
  stack, so the slot does not cover a long streamed or SSE body. If
  you are streaming inference tokens and need to bound the active
  streams, gate that work yourself.
- The slot is always released, even when the handler crashes. You
  cannot leak one.
- Under a burst the limit is approximate: a request that increments
  past the limit decrements again on its way out. That is exactly the
  behavior you want from load-shedding, not a bug.

## See also

- Reference: `livery_concurrency`
- Recipe: [Add per-request deadlines](add-deadlines.md)
- Recipe: [Cap request body size](cap-body-size.md)
