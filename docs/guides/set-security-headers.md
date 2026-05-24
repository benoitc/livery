# How to set security headers

## Problem

You want responses to carry baseline hardening headers
(`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`,
`Strict-Transport-Security`, optionally `Content-Security-Policy`).

## Solution

Add `livery_security_headers` to the stack. With no config it applies
sensible defaults:

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

`Strict-Transport-Security` is meaningless over plain HTTP, so it is
emitted only when the request is secure (`scheme` is `https` or TLS
info is present). Tune or disable it:

```erlang
{livery_security_headers, #{
    hsts => #{max_age => 63072000, include_subdomains => true, preload => true}
}}

{livery_security_headers, #{hsts => false}}  %% never send HSTS
```

## Content-Security-Policy is opt-in

A wrong CSP breaks pages, so there is no default. Set it explicitly:

```erlang
{livery_security_headers, #{csp => <<"default-src 'self'">>}}
```

## Overriding per header

Any key set to a value replaces the default; set it to `false` to drop
that header entirely:

```erlang
{livery_security_headers, #{
    frame_options => <<"SAMEORIGIN">>,
    referrer_policy => false
}}
```

A header the handler already set on the response is preserved, so a
handler can override any of these per response.

## See also

- Reference: `livery_security_headers`, `livery_cors`
- Recipe: [Enable CORS](enable-cors.md)
- Recipe: [Write a custom middleware](custom-middleware.md)
