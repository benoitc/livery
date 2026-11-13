# How to serve several certificates by hostname (SNI)

When a client opens a TLS (or QUIC) connection it sends the hostname
it is asking for in the ClientHello, as the Server Name Indication
(SNI, RFC 6066). You need SNI when one listener serves several
hostnames and each one has a different certificate: you look at that
name and return the matching certificate, instead of tying the
listener to a single `cert`/`key` pair.

## Install a per-hostname callback

Every adapter that uses TLS lets you install a callback that runs once
per connection, receives the SNI, and returns the certificate to send.
The option is not the same for every protocol, because HTTP/1.1 and
HTTP/2 run on Erlang's `ssl`, while HTTP/3 runs on QUIC's own TLS 1.3
code:

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

`ssl_opts` goes to `ssl:listen/2` as is: whatever you put there is
merged on top of the listener's own TLS defaults, so your options
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

QUIC runs the TLS handshake inside its own transport, so it does not
use `ssl_opts`. Pass `sni_callback` instead. It is called once per
connection with the SNI and returns the certificate map to send.

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

The callback returns DER-encoded data: `cert` is the server's own
certificate, `key` the private key term, and the optional
`cert_chain => [Der]` holds the intermediate certificates. An
`{error, _}`, a malformed result, or a raised exception fails the
handshake with a `handshake_failure` alert, so an unknown host closes
the connection instead of getting the wrong certificate.

## Share the same certificates on every protocol

To serve one hostname over H1, H2, and H3, give each TLS adapter its
own callback. The two differ only in what they return (an `ssl` option
list for `https`, a `{ok, CertMap}` for `http3`), so two small wrappers
around one lookup keep them in agreement:

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
and H2 responses so a client that supports H3 knows it can move up
to it.

## Notes

- The `ServerName` type depends on the listener: a charlist on `https`
  (what `ssl` passes to `sni_fun`), a binary on `http3`. When the client
  sends no SNI, `ssl` does not call `sni_fun` at all, while
  `sni_callback` receives `undefined`.
- Keep a static `cert`/`key` on the listener. On `https` it is the
  fallback whenever `sni_fun` returns `[]`; on `http3` it is the
  certificate used when no `sni_callback` is set. HTTP/3 needs
  `quic` >= 1.6.5 for `sni_callback`.
- The callback runs during the handshake, before the connection can
  go on. Keep it fast and with few side effects: look up a cached
  certificate, do not wait on the network. Load and parse certificates
  ahead of time and keep them in a table your callback reads.
- SNI selects the *certificate*, not the route. Once the handshake
  completes the request goes through the same router and middleware as
  any other; match on the `Host`/`:authority` header if you want each
  hostname to behave differently.

## See also

- How-to: [Bind to an address or IPv6](bind-listen-address.md)
- Concept: [Adapters](../concepts/adapters.md)
- Reference: `livery_service`, `livery_h2`, `livery_h3`
