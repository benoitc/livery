# How to rate-limit requests

`livery_ratelimit` limits how often each client may call the API and
answers `429 Too Many Requests` once a client goes over its allowance.
You need it to protect an endpoint from being called faster than it
can serve.

## Add it to the stack

Add `livery_ratelimit` with a state built by `limiter/2,3`. Each client
gets a token bucket: it holds up to `Capacity` tokens and gains
`RefillPerSec` tokens every second:

```erlang
Stack = [
    {livery_ratelimit, livery_ratelimit:limiter(100, 10)}  %% burst 100, 10/s
].
```

Each request takes one token. When the bucket is empty, the request
gets a `429` and the handler is not called. "N requests per minute" is
`limiter(N, N/60)` (bursts of up to N, then N/60 per second).

## Identify clients

By default the key is the bearer token from the Authorization header
(`livery_ext:bearer_token/1`). A request without a token is not
limited at all. Give your own `key` fun to limit by an API-key header,
by the client address (`livery_req:peer/1`, turned into a binary), or
anything else:

```erlang
livery_ratelimit:limiter(60, 1, #{
    key => fun(Req) -> livery_req:header(<<"x-api-key">>, Req) end
})
```

When your `key` fun returns `undefined`, that request is not limited.
Keys are hashed with SHA-256 before they are stored, so raw tokens
never stay in memory.

Keying on the bearer token gives each credential its own quota, but it
does not protect you from a flood: a client that keeps changing tokens
gets a new bucket each time. To protect against floods, key on an
identity the client cannot change at will (an authenticated user id,
or a forwarded-IP header you trust because you sit behind a known
proxy). The store also limits how many keys it holds
(`ratelimit_max_keys`, default 1,000,000) and removes idle buckets
every minute, so a flood of different keys cannot grow memory without
bound, whatever you key on.

## Tune headers and options

Responses to requests that get through carry `RateLimit-Limit`,
`RateLimit-Remaining`, and `RateLimit-Reset`; a `429` adds
`Retry-After`. Change them with these options:

```erlang
livery_ratelimit:limiter(100, 10, #{
    status => 429,                 %% shed status (default 429)
    body => <<"slow down">>,       %% shed body
    headers => false,              %% suppress all RateLimit-*/Retry-After
    name => my_api                 %% share one keyspace across stacks
})
```

Each `limiter/2,3` call gets its own set of keys, so a global limit
and tighter per-route limits do not affect each other. Pass the same
`name` when you want several stacks to share one budget.

## Notes

- The count stays exact when requests run in parallel: taking a token
  is a single compare-and-swap with no lock, so concurrent requests
  for the same key never let more through than the bucket allows.
- `RefillPerSec => 0` is a fixed quota that never refills. Those
  buckets are kept until the node restarts, because removing one would
  give the client a fresh quota.
- The state for each key lives in the `livery_ratelimit_store` ETS
  table, which is supervised. Idle buckets that have refilled
  completely are removed on their own.

## See also

- Reference: `livery_ratelimit`, `livery_ratelimit_store`
- Guide: [Limit concurrency](limit-concurrency.md)
- Guide: [Extract a bearer token](bearer-tokens.md)
