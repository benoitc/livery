# How to verify JWT access tokens

`livery_auth_bearer` checks the signed JWT a client sends in
`Authorization: Bearer`, against your authorization server's keys, and
refuses the request when the token is missing, invalid, meant for
someone else, or does not grant what the route needs. You need it when
your API is an OAuth resource server and your issuer hands out JWT
access tokens (Auth0, Keycloak, Okta, Azure AD, Cognito and most
others do).

## Find the issuer's keys

Ask the issuer for its metadata once, at startup, and keep the
`jwks_uri`:

```erlang
Issuer = <<"https://issuer.example">>,
{ok, Meta} = livery_auth_oidc:discover(Issuer),
JwksUri = maps:get(<<"jwks_uri">>, Meta).
```

For a plain OAuth server without OpenID Connect, use
`livery_auth_oidc:discover_oauth/1` instead (RFC 8414). Both refuse a
document that names another issuer.

## Protect a route

```erlang
Stack = [
    {livery_auth_bearer, #{
        jwks_uri => JwksUri,
        issuer   => Issuer,
        audience => <<"https://api.example">>,
        profile  => access_token,
        scope    => [<<"orders:read">>],
        realm    => <<"orders">>
    }}
].
```

`profile => access_token` applies RFC 9068: the token must say
`typ: at+jwt` and carry `iss`, `exp`, `aud`, `sub`, `client_id`, `iat`
and `jti`. Leave it out if your issuer does not follow the profile;
`issuer` and `audience` are still checked when you set them.

The handler reads the claims with `livery_ext:user/1`:

```erlang
fun(Req) ->
    #{<<"sub">> := Sub} = livery_ext:user(Req),
    livery_resp:text(200, [<<"hello ">>, Sub])
end.
```

## What the client gets back

| Situation | Status | `WWW-Authenticate` |
|---|---|---|
| no token | 401 | `Bearer realm="orders"` |
| expired, badly signed, wrong issuer or audience | 401 | `Bearer realm="orders", error="invalid_token", error_description="..."` |
| valid token, scope missing | 403 | `Bearer realm="orders", error="insufficient_scope", scope="orders:read"` |

With `required => false`, a request without a token goes through and
the handler sees no user; a bad token is still refused.

## Require a stronger or more recent sign-in

Some routes need more than a valid token: a payment, a change of
email, an admin action. Ask for a sign-in method (`acr_values`, as your
provider names them) or a recent sign-in (`max_age`, in seconds) on the
route's own stack:

```erlang
{livery_auth_bearer, #{
    jwks_uri   => JwksUri,
    issuer     => Issuer,
    audience   => <<"https://api.example">>,
    acr_values => [<<"urn:example:mfa">>],
    max_age    => 300
}}
```

A token from a weaker or older sign-in gets `401` with
`error="insufficient_user_authentication"` and the `acr_values` and
`max_age` to sign in again with (RFC 9470). The token has to carry
`acr` and `auth_time` for this; most providers add them to access tokens
when asked to.

## Tell clients where to get a token

Publish protected resource metadata (RFC 9728), so a client that gets a
`401` can find your authorization server, and point the challenge at
it:

```erlang
Resource = <<"https://api.example">>,
Meta = #{
    resource => Resource,
    authorization_servers => [Issuer],
    scopes_supported => [<<"orders:read">>]
},
Router1 = livery_router:add(
    <<"GET">>, livery_auth_resource:well_known_path(Resource),
    livery_auth_resource:handler(Meta), #{}, Router0
),
Bearer = {livery_auth_bearer, #{
    jwks_uri => JwksUri, issuer => Issuer, audience => Resource,
    resource_metadata => livery_auth_resource:well_known_url(Resource)
}}.
```

Set `resource` to the URL clients use, not the one your listener sees
behind a proxy.

## Verify a token yourself

`livery_auth:verify/2` does the same checks without the middleware:

```erlang
{ok, Keys} = livery_auth_jwks:keys(JwksUri),
case livery_auth:verify(Token, #{keys => Keys, issuer => Issuer, audience => Aud}) of
    {ok, Claims} -> {ok, Claims};
    {error, Reason} -> {error, Reason}
end.
```

## Notes

- Accepted algorithms: RS256/384/512, PS256/384/512, ES256/384/512,
  Ed25519, Ed448 and the older `EdDSA`. Narrow them with `algorithms`.
  `none` and HMAC are never accepted.
- A key is used only if its type, curve, `alg`, `use` and `key_ops`
  agree with the token. RSA keys under 2048 bits are refused.
- A token naming a key the cached set does not have makes Livery fetch
  the set again, at most once every 30 seconds
  (`min_refresh_interval`), so key rotation works, and tokens with
  made-up key ids cannot flood your issuer with requests.
- `scope` is read from the space-separated `scope` claim and from the
  `scp` list some issuers send instead.
- Allow for clock skew with `leeway`, in seconds.

## See also

- Guide: [Verify opaque tokens with introspection](token-introspection.md)
- Guide: [Require client certificates](require-client-certificates.md)
- Guide: [Bind access tokens to their clients](bind-tokens-to-clients.md)
- Reference: `livery_auth_bearer`, `livery_auth`, `livery_auth_jwks`, `livery_auth_oidc`
