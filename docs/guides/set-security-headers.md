# How to set security headers

## Problem

A security audit (or your own good sense) says every response should
carry the usual hardening headers: `X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy`, `Strict-Transport-Security`,
and maybe a `Content-Security-Policy`. You do not want to set them by
hand on each handler, you want them applied once, everywhere.

## Solution

Drop `livery_security_headers` into the stack. With no config at all
it picks sensible defaults:

```erlang
Stack = [
    {livery_security_headers, #{}}
    %% ... handler
].
```

Defaults emitted:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: no-referrer`
- `Strict-Transport-Security: max-age=31536000; includeSubDomains`
  (HTTPS / TLS requests only)

## HSTS only on secure requests

`Strict-Transport-Security` means nothing over plain HTTP, so Livery
only emits it when the request is actually secure (`scheme` is
`https`, or TLS info is present). You can tune it or turn it off:

```erlang
{livery_security_headers, #{
    hsts => #{max_age => 63072000, include_subdomains => true, preload => true}
}}

{livery_security_headers, #{hsts => false}}  %% never send HSTS
```

## Content-Security-Policy is opt-in

A wrong CSP will quietly break your pages, so there is no default on
purpose. When you are ready, set it explicitly:

```erlang
{livery_security_headers, #{csp => <<"default-src 'self'">>}}
```

## Overriding per header

Set any key to a value and it replaces the default; set it to
`false` to drop that header entirely:

```erlang
{livery_security_headers, #{
    frame_options => <<"SAMEORIGIN">>,
    referrer_policy => false
}}
```

And if a handler already set one of these on its response, that
value is left alone. So a handler always has the final say, per
response, when it needs one.

## See also

- Reference: `livery_security_headers`, `livery_cors`
- Recipe: [Enable CORS](enable-cors.md)
- Recipe: [Write a custom middleware](custom-middleware.md)
