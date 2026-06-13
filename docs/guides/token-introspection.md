# How to verify opaque tokens with introspection

`livery_auth_introspect` POSTs a token to the authorization
server's introspection endpoint and trusts the `active` field of
the JSON response (RFC 7662). You need it when your bearer tokens
are opaque reference tokens, not self-contained JWTs, so you cannot
verify them locally.

## Add it to the stack

The middleware authenticates this resource server with HTTP Basic.
On success the response (with `scope`, `sub`, `exp`, ...) is stored
under `meta(user, _)`:

```erlang
Stack = [
    {livery_auth_introspect, #{
        endpoint      => <<"https://issuer.example/oauth/introspect">>,
        client_id     => <<"my-api">>,
        client_secret => <<"s3cret">>
    }}
    %% ... handler
].
```

Read the claims in a handler with `livery_ext:user/1`:

```erlang
fun(Req) ->
    #{<<"sub">> := Sub, <<"scope">> := Scope} = livery_ext:user(Req),
    livery_resp:text(200, [<<"hello ">>, Sub, <<" (">>, Scope, <<")">>])
end.
```

A missing token is rejected with `401` unless `required => false`.
An inactive token (or any transport/decoding failure) is always
rejected with `401` and a `WWW-Authenticate: Bearer` header.

## Choose JWT or introspection

| Token kind | Use |
|---|---|
| Self-contained JWT | `livery_auth_bearer` (local verify, no round trip) |
| Opaque / reference | `livery_auth_introspect` (round trip per request) |

Introspection adds a network call per request. Cache results in
your own layer if the round trip is too costly.

## Plug in a custom HTTP client

The call is pluggable. Pass `fetch => fun((Url, Headers, Body) ->
{ok, Status, Body} | {error, _})` to use your own client or to
test without a network:

```erlang
#{endpoint => Endpoint,
  fetch => fun(_U, _H, _B) -> {ok, 200, <<"{\"active\":true}">>} end}
```

## See also

- Reference: `livery_auth_introspect`, `livery_ext`
- Guide: [Extract a bearer token](bearer-tokens.md)
