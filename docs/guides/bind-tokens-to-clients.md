# How to bind access tokens to their clients

A plain bearer token works for whoever holds it: copy it from a log or a
compromised proxy and you can call the API as its owner. A
sender-constrained token is tied to its client, so a stolen copy is
useless on its own. You need this when your tokens are worth stealing
and your authorization server can issue bound tokens. There are two
ways to bind them, and Livery checks both:

| Binding | The client proves it with | Token claim | Spec |
|---|---|---|---|
| mutual TLS | the TLS client certificate | `cnf.x5t#S256` | RFC 8705 |
| DPoP | a signed proof on every request | `cnf.jkt` | RFC 9449 |

## Check bound tokens

`livery_auth_bearer` and `livery_auth_introspect` already refuse a bound
token presented by the wrong client: a certificate-bound token from a
connection without that certificate, or a DPoP-bound token sent as a
plain `Bearer`. To accept DPoP proofs, turn the scheme on:

```erlang
{livery_auth_bearer, #{
    jwks_uri => JwksUri,
    issuer   => Issuer,
    audience => <<"https://api.example">>,
    dpop     => true
}}
```

The client then sends `Authorization: DPoP <token>` and a `DPoP` header
with its proof. Livery checks the proof (method, URL, age, access token
hash, single use) and that its key is the one the token names.

## Require bound tokens

To refuse plain bearer tokens altogether, say which binding you want:

```erlang
{livery_auth_bearer, #{
    jwks_uri => JwksUri,
    issuer   => Issuer,
    audience => <<"https://api.example">>,
    binding  => dpop
}}
```

`binding` is `none` (default), `mtls`, `dpop` or `any`. With `dpop`, the
challenge no longer offers `Bearer`, so clients know to use DPoP.

For `mtls`, the listener has to ask for client certificates; see
[Require client certificates](require-client-certificates.md).

## Require fresh proofs with a server nonce

A client creates its own proofs, so one that had its DPoP key copied
for a moment could have proofs made for later. With a server nonce
(RFC 9449 section 9), each proof has to carry a value your server
handed out shortly before:

```erlang
#{dpop => true,
  dpop_nonce => #{secret => NonceSecret, ttl => 300}}
```

A proof without a valid nonce gets `401` with
`error="use_dpop_nonce"` and a `DPoP-Nonce` header; the client retries
with that value. Every answer to a DPoP request carries the next
nonce, so a busy client rarely sees the `401`. Nonces are a timestamp
signed with the secret, nothing is stored, and nodes that share the
secret accept each other's nonces.

## Behind a proxy

A DPoP proof names the URL the client called. When a proxy rewrites the
scheme, host or path, tell Livery the public URL:

```erlang
#{dpop => true,
  dpop_url => fun(Req) ->
      <<"https://api.example", (livery_req:path(Req))/binary>>
  end}
```

## Notes

- A proof is accepted for 60 seconds after its `iat`
  (`dpop_iat_window`), plus `leeway`.
- Each proof is accepted once. The record of used proofs lives in the
  node. In a cluster, give every node the same store with
  `dpop_replay => fun((Key, ExpiresAt) -> fresh | replayed)`, or a
  proof could be replayed against another node.
- Browser clients on another origin can only read `DPoP-Nonce` if CORS
  exposes it: add `<<"dpop-nonce">>` to `expose` in `livery_cors`.
- Tell clients what you accept by publishing protected resource
  metadata; see [Verify JWT access tokens](verify-access-tokens.md).

## See also

- Reference: `livery_auth_binding`, `livery_auth_dpop`, `livery_auth_bearer`
- Guide: [Verify JWT access tokens](verify-access-tokens.md)
