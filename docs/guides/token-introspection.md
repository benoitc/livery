# How to verify opaque tokens with introspection

## Problem

Your bearer tokens are opaque reference strings, not self-contained
JWTs. There is nothing inside them to verify locally, so the only
way to know whether a token is still good is to ask the
authorization server that issued it. That conversation is token
introspection (RFC 7662).

## Solution

`livery_auth_introspect` does that round trip for you. It POSTs the
token to the introspection endpoint, identifies your resource server
with HTTP Basic, and looks at the `active` field of the JSON it gets
back. When the token is active, the full response (`scope`, `sub`,
`exp`, and friends) is stored under `meta(user, _)`:

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

A missing token gets a `401`, unless you pass `required => false`.
An inactive token - or any failure to reach or decode the response -
is always a `401`, together with a `WWW-Authenticate: Bearer`
header. When in doubt, the request is turned away.

## JWT vs. introspection

| Token kind | Use |
|---|---|
| Self-contained JWT | `livery_auth_bearer` (local verify, no round trip) |
| Opaque / reference | `livery_auth_introspect` (round trip per request) |

Keep in mind that introspection costs a network call on every
request. If that round trip starts to hurt, cache the results in a
layer of your own.

## Custom HTTP client

The HTTP call is pluggable, which is handy both in production and in
tests. Pass `fetch => fun((Url, Headers, Body) -> {ok, Status, Body}
| {error, _})` to swap in your own client, or to stub the whole
thing out so your tests never touch the network:

```erlang
#{endpoint => Endpoint,
  fetch => fun(_U, _H, _B) -> {ok, 200, <<"{\"active\":true}">>} end}
```

## See also

- Reference: `livery_auth_introspect`, `livery_ext`
- Recipe: [Extract a bearer token](bearer-tokens.md)
