# How to sign users in with OpenID Connect

`livery_auth_login` lets people sign in to your web app with an identity
provider (Google, Microsoft Entra, Okta, Auth0, Keycloak, or any OpenID
Connect provider). You need it when you would rather not store passwords
yourself: the provider checks who the user is, and your app gets a
signed session cookie with their identity.

## Register your app

At your provider, create an application of type "web" and note its
client id and secret. Set its redirect URI to your callback, for example
`https://app.example/auth/callback`.

## Add the routes

```erlang
{ok, Provider} = livery_auth_oidc:discover(<<"https://accounts.example">>),
Login = #{
    provider      => Provider,
    client_id     => <<"my-app">>,
    client_secret => <<"s3cret">>,
    redirect_uri  => <<"https://app.example/auth/callback">>,
    scope         => [<<"email">>, <<"profile">>],
    session       => #{secret => SessionSecret, max_age => 8 * 3600}
},
Router = livery_router:compile(livery_auth_login:routes(Login) ++ AppRoutes).
```

This adds `GET /login`, the callback at the path of `redirect_uri`, and
`/logout` (GET and POST). `openid` is always requested.

Send people to `/login?return_to=/orders` to come back to `/orders`
after signing in.

## Read the user in your handlers

Put the session middleware in front of your routes, with the same
session options:

```erlang
Stack = [{livery_auth_session, #{secret => SessionSecret}}],

Handler = fun(Req) ->
    case livery_ext:session(Req) of
        #{<<"sub">> := Sub} -> livery_resp:text(200, [<<"hello ">>, Sub]);
        undefined -> livery_resp:redirect(302, <<"/login?return_to=/">>)
    end
end.
```

The session holds `sub`, `iss`, and `name` and `email` when the provider
sent them.

## Choose what goes in the session

`on_login` receives the validated ID token claims and the token
response, and returns the session map. Keep it small, since it travels
in a cookie:

```erlang
Login#{on_login => fun(Claims, _Token) ->
    #{<<"uid">> => lookup_user(maps:get(<<"sub">>, Claims))}
end}
```

## Ask for a stronger sign-in when a route needs it

When your API answers `insufficient_user_authentication` (see
[Verify JWT access tokens](verify-access-tokens.md)), send the user back
through login with what it asked for:

```erlang
Login#{step_up_acr_values => [<<"urn:example:mfa">>]}
%% then redirect to
%% /login?acr_values=urn:example:mfa&max_age=300&return_to=/payments
```

Only the levels listed in `step_up_acr_values` are taken from the link,
so nobody can make a login link that asks for a level of their own
choosing. Set
`acr_values` or `max_age` in the options to ask for them on every login.
The callback refuses an ID token whose `acr` is not one requested, or
whose `auth_time` is older than `max_age`, and the session keeps `acr`
and `auth_time` so your handlers can check them too.

## Keep the login request out of the URL

When the provider supports pushed authorization requests (RFC 9126, it
then lists `pushed_authorization_request_endpoint` in its metadata),
Livery sends the login parameters to the provider directly first, and
the browser only carries a short reference. Nothing to configure:
`par => auto` is the default. Set `par => false` to put the parameters
in the redirect URL as before, unless the provider requires PAR, in
which case Livery always uses it. With PAR, PKCE, `private_key_jwt` and
DPoP-bound tokens, your app follows the FAPI 2.0 security profile (the
OpenID Foundation's rules for high-security APIs).

## What is checked for you

- `state` and a PKCE verifier tie the callback to the browser that
  started the login.
- The provider's `iss` in the callback, when it sends one (RFC 9207).
- The ID token: signature, issuer, audience, `azp`, expiry, the `nonce`
  sent at login, and `at_hash` when present.
- `return_to` is followed only when it is a local path, so `/login`
  cannot redirect to another site.

## Notes

- Keep the session `secret` long and random, and the same on every node.
- `/logout` clears the session and, when the provider has an
  `end_session_endpoint`, sends the browser there to sign out of the
  provider too. Register `post_logout_redirect_uri` with the provider to
  come back to your app afterwards. Without the ID token as a hint the
  provider asks the user to confirm; `keep_id_token => true` keeps it in
  the session for that, at the cost of a larger cookie.
  `provider_logout => false` signs out of your app only.
- Being told about a sign-out that happened at the provider (back-channel
  or front-channel logout) is not supported: sessions live in cookies,
  so there is nothing on the server to end.
- Pass `client_auth => private_key_jwt` and `private_key` instead of
  `client_secret` to authenticate with a key, as in
  [Call an API with OAuth](call-apis-with-oauth.md).
- Add provider-specific parameters, such as `prompt`, with
  `params => [{<<"prompt">>, <<"select_account">>}]`.

## See also

- Reference: `livery_auth_login`, `livery_auth_session`, `livery_auth_oidc`
- Guide: [Use signed session cookies](session-cookies.md)
