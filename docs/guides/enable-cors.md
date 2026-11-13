# How to enable CORS

`livery_cors` is a middleware that adds Cross-Origin Resource Sharing
headers to your responses and answers preflight `OPTIONS` requests. You
need it when a browser app served from another origin calls your API:
without these headers the browser blocks the response.

## Add it to the stack

Every config key is optional. The default allows any origin:

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
your handler never runs. A normal request runs the handler, then the CORS
headers are added to its response.

## Match origins

```erlang
origins => '*'                                  %% any origin (default)
origins => [<<"https://a.test">>, <<"https://b.test">>]
origins => fun(Origin) -> is_tenant_origin(Origin) end
```

When the origin is not allowed, no `Access-Control-Allow-Origin` is
sent and the browser blocks the response.

## Use credentials

`Access-Control-Allow-Origin: *` is not allowed with credentials. When you set
`credentials => true`, `livery_cors` echoes the request `Origin` instead
of `*` and adds `Access-Control-Allow-Credentials: true`.

## Notes

- `Vary` is set for you, so shared caches do not hand one origin's
  response to another. `Vary: Origin` is added to every response that
  depends on the origin (any config except a plain `'*'` without
  credentials), and preflights with `headers => mirror` also add
  `Vary: Access-Control-Request-Headers`. A value already in `Vary` is
  never added twice.
- A plain `origins => '*'` without credentials gives the same answer to
  every origin, so no `Vary` is added.

## See also

- Reference: `livery_cors`, `livery_security_headers`
- Guide: [Set security headers](set-security-headers.md)
- Guide: [Write a custom middleware](custom-middleware.md)
