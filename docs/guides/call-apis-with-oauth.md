# How to call an API that wants an OAuth token

`livery_client:oauth/1` is a client layer that gets an access token from
your authorization server and adds it to every outbound request. You
need it when your service calls another API as itself (no user
involved), the OAuth client credentials grant: service-to-service calls,
batch jobs, webhooks to a partner.

## Add the layer

```erlang
Client = livery_client:new(#{
    base_url => <<"https://orders.example">>,
    stack    => [
        livery_client:timeout(5000),
        livery_client:oauth(#{
            token_endpoint => <<"https://issuer.example/oauth/token">>,
            client_id      => <<"billing">>,
            client_secret  => <<"s3cret">>,
            scope          => [<<"orders:read">>],
            allowed_origins => [<<"https://orders.example">>]
        })
    ]
}),
{ok, Resp} = livery_client:get(Client, <<"/orders/42">>).
```

`allowed_origins` says where the token may go. A request to any other
scheme, host or port, through an absolute URL or a layer that rewrites
it, fails with `{error, {credential_not_allowed, Url}}` before anything
is sent. With `resource` set (below), its origin is used and
`allowed_origins` can be left out.

The first request fetches a token; the next ones reuse it until 30
seconds before it expires (`refresh_skew`). When it runs out under load,
every waiting request shares one new token instead of each asking for
its own.

If the API answers `401` with `error="invalid_token"` (the token was
revoked), the layer gets a new one and sends the request once more.

## Authenticate without a shared secret

A signed assertion keeps the secret off the wire (RFC 7523). Register
the public key with your authorization server and keep the private key:

```erlang
{ok, Pem} = file:read_file("client-key.pem"),
[Entry] = public_key:pem_decode(Pem),
livery_client:oauth(#{
    token_endpoint => <<"https://issuer.example/oauth/token">>,
    issuer         => <<"https://issuer.example">>,
    client_id      => <<"billing">>,
    client_auth    => private_key_jwt,
    private_key    => {<<"ES256">>, public_key:pem_entry_decode(Entry)},
    key_id         => <<"billing-2026">>,
    allowed_origins => [<<"https://orders.example">>]
}).
```

`issuer` is the authorization server's issuer identifier, found in its
metadata (`livery_auth_oidc:discover_oauth/1`). It is the only audience
of the assertion, as RFC 10070 requires.

For mutual TLS, use `client_auth => tls_client_auth` and put the client
certificate in `adapter_opts` for hackney.

## Ask for a token for one API

When the authorization server protects several APIs, name the one you
call with `resource` (RFC 8707):

```erlang
livery_client:oauth(#{
    token_endpoint => TokenEndpoint,
    client_id      => <<"billing">>,
    client_secret  => Secret,
    resource       => <<"https://orders.example">>
}).
```

## Bind the token to your client with DPoP

A bearer token works for anyone who copies it. With DPoP (RFC 9449), the
token is bound to a key your client keeps, and every request carries a
proof signed with it, so a copied token is useless on its own. Your
authorization server has to support DPoP; turn it on with `dpop`:

```erlang
livery_client:oauth(#{
    token_endpoint  => TokenEndpoint,
    client_id       => <<"billing">>,
    client_secret   => Secret,
    allowed_origins => [<<"https://orders.example">>],
    dpop            => true
}).
```

The layer generates an ES256 key, sends a proof with the token request,
then `Authorization: DPoP <token>` and a fresh proof on every API
request, made for its method and URL. When a server asks for a nonce
(`use_dpop_nonce`), the request is sent once more with it, and later
proofs to that server carry the latest one.

To use your own key, pass it: `dpop => #{key => {<<"ES256">>, PrivateKey}}`.
An authorization server that does not bind the token answers with a
bearer token, which is then sent as bearer; add `require => true` to the
`dpop` map to refuse it instead.

## Get a token yourself

`livery_auth_token:request/3` is the same token request without the
layer, for the `client_credentials`, `authorization_code` and
`refresh_token` grants:

```erlang
{ok, #{access_token := Token, expires_at := Exp}} =
    livery_auth_token:request(client_credentials, #{scope => <<"orders:read">>}, #{
        token_endpoint => TokenEndpoint,
        client_id      => <<"billing">>,
        client_secret  => Secret
    }).
```

## Notes

- `client_auth` is `client_secret_basic` (default), `client_secret_post`,
  `private_key_jwt`, `tls_client_auth` or `none`.
- Errors from the authorization server come back as
  `{error, {oauth_error, Code, Description}}`, for example
  `invalid_client` or `invalid_scope`.
- Tokens are cached per node, keyed by endpoint, client, scope,
  resource and DPoP key.
- Without `dpop`, a server that issues DPoP tokens gets
  `{error, {unsupported_token_type, <<"DPoP">>}}`.
- A generated DPoP key lives in memory, shared by the clients of the
  same endpoint and client id on the node. After a restart a new key is
  made and new tokens are fetched for it.

## See also

- Reference: `livery_client_oauth`, `livery_client_dpop`, `livery_auth_token`, `livery_client`
- Guide: [Bind access tokens to their clients](bind-tokens-to-clients.md)
- Guide: [Make outbound HTTP requests](make-http-requests.md)
