# How to enable CORS

## Problem

A browser app on another origin needs to call your API, so the
responses must carry Cross-Origin Resource Sharing headers and
preflight `OPTIONS` requests must be answered.

## Solution

Add `livery_cors` to the stack. Every config key is optional; the
default allows any origin:

```erlang
Stack = [
    {livery_cors, #{
        origins => [<<"https://app.example.com">>],
        methods => [<<"GET">>, <<"POST">>],
        headers => mirror,            %% echo Access-Control-Request-Headers
        expose  => [<<"x-total-count">>],
        credentials => true,
        max_age => 600
    }}
    %% ... handler
].
```

A preflight (`OPTIONS` carrying `Access-Control-Request-Method`) is
answered directly with `204` and the `Access-Control-Allow-*` headers;
the handler is never called. A normal request runs the handler, then
the CORS response headers are added.

## Origins

```erlang
origins => '*'                                  %% any origin (default)
origins => [<<"https://a.test">>, <<"https://b.test">>]
origins => fun(Origin) -> is_tenant_origin(Origin) end
```

When the origin is not allowed, no `Access-Control-Allow-Origin` is
emitted and the browser blocks the response.

## Credentials and the wildcard

`Access-Control-Allow-Origin: *` is invalid with credentials. When
`credentials => true`, `livery_cors` always echoes the request
`Origin` instead of `*` and adds `Access-Control-Allow-Credentials:
true`.

## Caching is handled for you

`livery_cors` sets `Vary` so shared caches stay correct:

- `Vary: Origin` is added on every response (allowed, denied, and the
  no-`Origin` passthrough) whenever the output depends on the request
  origin, which is any config except the plain non-credentialed `'*'`.
- Mirroring preflights also add `Vary: Access-Control-Request-Headers`.
- A plain `origins => '*'` without credentials is origin-independent,
  so no `Vary` is added.

Existing `Vary` tokens are never duplicated.

## See also

- Reference: `livery_cors`, `livery_security_headers`
- Recipe: [Set security headers](set-security-headers.md)
- Recipe: [Write a custom middleware](custom-middleware.md)
