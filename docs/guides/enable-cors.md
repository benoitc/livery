# How to enable CORS

## Problem

Your frontend lives on one origin and your API on another, and the
browser refuses to let them talk until the API plays by the
Cross-Origin Resource Sharing rules. That means your responses need
the right CORS headers, and the preflight `OPTIONS` requests need a
proper answer.

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

A preflight (an `OPTIONS` carrying `Access-Control-Request-Method`)
is answered right away with `204` and the `Access-Control-Allow-*`
headers, and your handler never sees it. A normal request runs the
handler as usual, and the CORS headers are added on the way out.

## Origins

```erlang
origins => '*'                                  %% any origin (default)
origins => [<<"https://a.test">>, <<"https://b.test">>]
origins => fun(Origin) -> is_tenant_origin(Origin) end
```

When an origin is not on the list, no `Access-Control-Allow-Origin`
goes out, and the browser blocks the response for you.

## Credentials and the wildcard

Here is a rule that trips people up: `Access-Control-Allow-Origin:
*` is illegal once credentials are involved. So when you set
`credentials => true`, `livery_cors` quietly echoes the request
`Origin` instead of `*` and adds `Access-Control-Allow-Credentials:
true`. You do not have to think about it.

## Caching is handled for you

Shared caches can serve the wrong response to the wrong origin if
`Vary` is not set right, so `livery_cors` takes care of it:

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
