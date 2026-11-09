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
An inactive token, or any transport or decoding failure, is always
rejected with `401` and `WWW-Authenticate: Bearer error="invalid_token"`.

## Check who the token is for and what it grants

The authorization server only says whether a token is active. Whether
it is meant for your API, and whether it allows this request, is your
call (RFC 7662 section 4). Set `audience` and `scope`:

```erlang
{livery_auth_introspect, #{
    endpoint      => <<"https://issuer.example/oauth/introspect">>,
    client_id     => <<"my-api">>,
    client_secret => <<"s3cret">>,
    audience      => <<"https://api.example">>,
    scope         => [<<"orders:read">>],
    realm         => <<"orders">>
}}
```

A token for another audience gets `401`. A token without one of the
scopes gets `403` with `error="insufficient_scope"` and the scopes it
needs, so a client knows to ask for more.

## Choose JWT or introspection

| Token kind | Use |
|---|---|
| Self-contained JWT | `livery_auth_bearer` (local verify, no round trip) |
| Opaque / reference | `livery_auth_introspect` (round trip per request) |

Introspection adds a network call per request and Livery does not
cache the answers. Cache them in your own layer if the round trip is
too costly, and keep the cache shorter than the token's `exp`.

## Plug in a custom HTTP client

The call is pluggable. Pass `fetch => fun((Url, Headers, Body) ->
{ok, Status, Body} | {error, _})` to use your own client or to
test without a network:

```erlang
#{endpoint => Endpoint,
  fetch => fun(_U, _H, _B) -> {ok, 200, <<"{\"active\":true}">>} end}
```

## Notes

- `client_id` and `client_secret` are form-encoded before they go into
  the Basic header, as RFC 6749 section 2.3.1 asks, so secrets with
  `:` or `+` work.

## See also

- Reference: `livery_auth_introspect`, `livery_ext`
- Guide: [Verify JWT access tokens](verify-access-tokens.md)
- Guide: [Extract a bearer token](bearer-tokens.md)
