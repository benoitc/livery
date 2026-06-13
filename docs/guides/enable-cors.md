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
emitted and the browser blocks the response.

## Use credentials

`Access-Control-Allow-Origin: *` is invalid with credentials. When you set
`credentials => true`, `livery_cors` echoes the request `Origin` instead
of `*` and adds `Access-Control-Allow-Credentials: true`.

## Notes

- `Vary` is set for you so shared caches stay correct. `Vary: Origin` is
  added to every response whose output depends on the origin (any config
  except a plain non-credentialed `'*'`), and mirroring preflights also add
  `Vary: Access-Control-Request-Headers`. Existing `Vary` tokens are never
  duplicated.
- A plain `origins => '*'` without credentials is origin-independent, so no
  `Vary` is added.

## See also

- Reference: `livery_cors`, `livery_security_headers`
- Guide: [Set security headers](set-security-headers.md)
- Guide: [Write a custom middleware](custom-middleware.md)
