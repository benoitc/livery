# How to rate-limit requests

`livery_ratelimit` throttles how fast each client may call the API and
answers `429 Too Many Requests` once a client exceeds its allowance.
You need it to protect an endpoint from being called faster than it
can serve.

## Add it to the stack

Add `livery_ratelimit` with the `limiter/2,3` factory. Each client
gets a token bucket of `Capacity` tokens that refills at
`RefillPerSec`:

```erlang
Stack = [
    {livery_ratelimit, livery_ratelimit:limiter(100, 10)}  %% burst 100, 10/s
].
```

A request consumes a token; an empty bucket sheds `429` (the handler
is not called). "N requests per minute" maps to `limiter(N, N/60)`
(burst N, sustained N/60).

## Identify clients

The client IP is NOT available (the wire libraries do not surface the
peer address), so the default key is the Authorization bearer token
(`livery_ext:bearer_token/1`). A request with no token is NOT limited.
Provide your own `key` fun to throttle by an API-key header or
anything else:

```erlang
livery_ratelimit:limiter(60, 1, #{
    key => fun(Req) -> livery_req:header(<<"x-api-key">>, Req) end
})
```

A `key` fun that returns `undefined` skips limiting for that request.
Keys are SHA-256 hashed before storage, so raw tokens are never kept
in memory.

The bearer-token default gives per-credential quotas, not flood
protection: a client that rotates tokens gets a fresh bucket each
time. For flood protection, key on an identity the client cannot
freely rotate (an authenticated user id, or a forwarded-IP header you
trust because you sit behind a known proxy). The store also caps its
total key count (`ratelimit_max_keys`, default 1,000,000) and reaps
idle buckets every minute, so a distinct-key flood bounds memory
regardless of the key.

## Tune headers and options

Allowed responses carry `RateLimit-Limit`, `RateLimit-Remaining`, and
`RateLimit-Reset`; a `429` adds `Retry-After`. Tune with:

```erlang
livery_ratelimit:limiter(100, 10, #{
    status => 429,                 %% shed status (default 429)
    body => <<"slow down">>,       %% shed body
    headers => false,              %% suppress all RateLimit-*/Retry-After
    name => my_api                 %% share one keyspace across stacks
})
```

Each `limiter/2,3` call allocates an isolated keyspace, so a global
limit and tighter per-route limits do not interfere. Pass an explicit
`name` to deliberately share one budget across several stacks.

## Notes

- The token bucket is approximate-free under concurrency: the consume
  is a lock-free compare-and-swap, so parallel requests for the same
  key never over-admit.
- `RefillPerSec => 0` is a pure fixed quota (no refill); those buckets
  are kept until the node restarts (they cannot be safely reclaimed
  without granting fresh quota).
- Per-key state lives in the supervised `livery_ratelimit_store` ETS
  table; idle buckets that have fully refilled are reclaimed
  automatically.

## See also

- Reference: `livery_ratelimit`, `livery_ratelimit_store`
- Guide: [Limit concurrency](limit-concurrency.md)
- Guide: [Extract a bearer token](bearer-tokens.md)
