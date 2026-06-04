# How to rate-limit requests

## Problem

One eager client is hammering your API and starving everyone else, or
you simply want fair quotas per caller. Either way, you want to cap how
fast each client can call you and reply `429 Too Many Requests` once it
goes over its share.

## Solution

Add `livery_ratelimit` with the `limiter/2,3` factory. Each client gets
its own token bucket: it holds up to `Capacity` tokens and tops back up
at `RefillPerSec`:

```erlang
Stack = [
    {livery_ratelimit, livery_ratelimit:limiter(100, 10)}  %% burst 100, 10/s
].
```

Every request spends one token. When the bucket runs dry the request is
shed with a `429` and your handler never runs. Want "N requests per
minute"? That is `limiter(N, N/60)`: a burst of N, sustained at N/60.

## Identifying clients

Heads up: the client IP is NOT available here, because the wire
libraries do not surface the peer address. So the default key is the
Authorization bearer token (`livery_ext:bearer_token/1`), and a request
with no token is NOT limited at all. To key on something else, an
API-key header or whatever you like, pass your own `key` fun:

```erlang
livery_ratelimit:limiter(60, 1, #{
    key => fun(Req) -> livery_req:header(<<"x-api-key">>, Req) end
})
```

If your `key` fun returns `undefined`, that request is left alone. Keys
are SHA-256 hashed before they hit storage, so raw tokens never sit in
memory.

One thing to keep in mind: the bearer-token default gives you
per-credential quotas, not flood protection. A client that keeps
rotating tokens just keeps getting fresh buckets. For real flood
protection, key on something the client cannot freely change: an
authenticated user id, or a forwarded-IP header you trust because you
know the proxy in front of you. The store also caps how many keys it
holds (`ratelimit_max_keys`, 1,000,000 by default) and sweeps idle
buckets every minute, so even a flood of distinct keys keeps memory
bounded.

## Headers and options

Allowed responses come back with `RateLimit-Limit`,
`RateLimit-Remaining`, and `RateLimit-Reset`, and a `429` adds
`Retry-After` so clients know when to come back. Tune the rest with:

```erlang
livery_ratelimit:limiter(100, 10, #{
    status => 429,                 %% shed status (default 429)
    body => <<"slow down">>,       %% shed body
    headers => false,              %% suppress all RateLimit-*/Retry-After
    name => my_api                 %% share one keyspace across stacks
})
```

Each `limiter/2,3` call gets its own isolated keyspace, so a global
limit and tighter per-route limits never step on each other. When you
actually do want several stacks to share one budget, give them the same
explicit `name`.

## Notes

- The token bucket is approximate-free under concurrency: the consume is
  a lock-free compare-and-swap, so parallel requests for the same key
  never over-admit.
- `RefillPerSec => 0` is a pure fixed quota (no refill); those buckets
  are kept until the node restarts (they cannot be safely reclaimed
  without granting fresh quota).
- Per-key state lives in the supervised `livery_ratelimit_store` ETS
  table; idle buckets that have fully refilled are reclaimed
  automatically.

## See also

- Reference: `livery_ratelimit`, `livery_ratelimit_store`
- Recipe: [Limit concurrency](limit-concurrency.md)
- Recipe: [Extract a bearer token](bearer-tokens.md)
