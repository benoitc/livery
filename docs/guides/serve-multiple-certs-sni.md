# How to serve several certificates by hostname (SNI)

When a client opens a TLS (or QUIC) connection it sends the hostname
it is asking for in the ClientHello, as the Server Name Indication
(SNI, RFC 6066). You need SNI when one listener serves several
hostnames and each one has a different certificate: you look at that
name and hand back the matching certificate, instead of pinning the
listener to a single `cert`/`key` pair.

## Install a per-hostname callback

Every TLS-bearing adapter lets you install a callback that runs once
per connection, receives the SNI, and returns the certificate to
present. The hook differs by protocol, because HTTP/1.1 and HTTP/2 run
on Erlang's `ssl`, while HTTP/3 runs on QUIC's own TLS 1.3 stack:

| Key | Protocol | Option | Callback |
|---|---|---|---|
| `https` | HTTP/1.1 (TLS), HTTP/2 | `ssl_opts => [{sni_fun, Fun}]` | `fun((ServerName) -> [ssl:tls_server_option()])` |
| `http3` | HTTP/3 (QUIC) | `sni_callback => Fun` | `fun((ServerName) -> {ok, CertMap})` |

On `https` the callback is Erlang's standard `sni_fun`: it returns a
list of `ssl` options (typically `certfile`/`keyfile`, or `cert`/`key`)
that override the defaults for that handshake. On `http3` the callback
returns `{ok, #{cert := Der, key := Key}}` (with an optional
`cert_chain => [Der]`), or `{error, Reason}` to refuse the handshake.

## HTTP/1.1 and HTTP/2

`ssl_opts` is a passthrough to `ssl:listen/2`: whatever you put there
is merged on top of the listener's own TLS defaults, so your options
win. Install `sni_fun` to pick the certificate per hostname.

```erlang
SniFun = fun(ServerName) ->
    case cert_store:lookup(ServerName) of
        {ok, CertFile, KeyFile} ->
            [{certfile, CertFile}, {keyfile, KeyFile}];
        not_found ->
            %% Falls back to the listener's own cert/key below.
            []
    end
end,

{ok, Pid} = livery:start_service(#{
    https => #{
        port => 8443,
        cert => DefaultCertFile,
        key  => DefaultKeyFile,
        ssl_opts => [{sni_fun, SniFun}]
    },
    router => Router
}).
```

`ServerName` is a charlist (for example `"api.example.com"`), the form
Erlang's `ssl` hands to `sni_fun`. Keep the listener's `cert`/`key`:
they are the fallback for clients that send no SNI, or a name your
callback does not recognise.

## HTTP/3 (QUIC)

QUIC negotiates TLS inside its own transport, so it does not use
`ssl_opts`. Pass `sni_callback` instead. It is called once per
connection with the SNI and returns the certificate map to present.

```erlang
SniCallback = fun(ServerName) ->
    %% ServerName is a binary here, e.g. <<"api.example.com">>,
    %% or `undefined' when the client sent no SNI.
    case cert_store:lookup_der(ServerName) of
        {ok, CertDer, KeyDer} -> {ok, #{cert => CertDer, key => KeyDer}};
        not_found             -> {error, unknown_host}
    end
end,

{ok, Pid} = livery:start_service(#{
    http3 => #{
        port => 8443,
        cert => DefaultCertDer,
        key  => DefaultKeyDer,
        sni_callback => SniCallback
    },
    router => Router
}).
```

The callback returns DER-encoded material: `cert` is the leaf
certificate, `key` the private key term, and the optional
`cert_chain => [Der]` carries intermediates. An `{error, _}`, a
malformed result, or a raised exception fails the handshake with a
`handshake_failure` alert, so a missing host closes the connection
rather than serving the wrong certificate.

## Share the same certificates on every protocol

To serve one hostname over H1, H2, and H3, give each TLS adapter its
own hook. The two callbacks differ only in their return shape (an
`ssl` option list for `https`, a `{ok, CertMap}` for `http3`), so a
small wrapper around one lookup keeps them in step:

```erlang
Lookup = fun(Name) -> cert_store:lookup(Name) end,

SniFun = fun(ServerName) ->
    case Lookup(list_to_binary(ServerName)) of
        {ok, CertFile, KeyFile, _Der} ->
            [{certfile, CertFile}, {keyfile, KeyFile}];
        not_found ->
            []
    end
end,

SniCallback = fun(ServerName) ->
    case Lookup(ServerName) of
        {ok, _File, _File2, {CertDer, KeyDer}} ->
            {ok, #{cert => CertDer, key => KeyDer}};
        not_found ->
            {error, unknown_host}
    end
end,

{ok, Pid} = livery:start_service(#{
    https => #{
        port => 8443,
        cert => DefaultCertFile, key => DefaultKeyFile,
        ssl_opts => [{sni_fun, SniFun}]
    },
    http3 => #{
        port => 8443,
        cert => DefaultCertDer, key => DefaultKeyDer,
        sni_callback => SniCallback
    },
    alt_svc => advertise,
    router  => Router
}).
```

`https` and `http3` share the port number because one is TCP and the
other UDP. `alt_svc => advertise` puts an `Alt-Svc` header on the H1
and H2 responses so a capable client knows it can move up to H3.

## Notes

- The `ServerName` type differs by stack: a charlist on `https` (what
  `ssl` passes `sni_fun`), a binary on `http3`. Both receive `undefined`
  when the client sends no SNI.
- Keep a static `cert`/`key` on the listener. On `https` it is the
  fallback whenever `sni_fun` returns `[]`; on `http3` it is the
  certificate used when no `sni_callback` is set. HTTP/3 needs
  `quic` >= 1.6.5 for `sni_callback`.
- The callback runs on the listener's connection path, in the
  handshake. Keep it fast and side-effect-light: look up a cached
  certificate, do not block on the network. Load and parse certificates
  ahead of time and keep them in a table your callback reads.
- SNI selects the *certificate*, not the route. Once the handshake
  completes the request flows through the same router and middleware as
  any other; match on the `Host`/`:authority` header if you want
  per-hostname behaviour.

## See also

- How-to: [Bind to an address or IPv6](bind-listen-address.md)
- Concept: [Adapters](../concepts/adapters.md)
- Reference: `livery_service`, `livery_h2`, `livery_h3`
