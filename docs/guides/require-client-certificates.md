# How to require client certificates (mutual TLS)

With mutual TLS the client proves who it is during the handshake, with a
certificate signed by a CA you trust. You need it when your callers are
machines rather than people (services, devices, sync peers) and you want
to refuse anyone without a certificate before a single request is read.
Livery turns it on per listener and puts the verified certificate on the
request, so your handler or middleware can decide what that client may
do.

## Ask for a certificate

Give each TLS listener `verify => verify_peer` and the CA certificates
that sign your clients, as DER binaries in `cacerts`:

```erlang
{ok, CaPem} = file:read_file("clients-ca.pem"),
CaCerts = [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(CaPem)],

{ok, _} = livery:start_service(#{
    https => #{
        port => 8443, cert => "server.pem", key => "server-key.pem",
        verify => verify_peer, cacerts => CaCerts
    },
    http3 => #{
        port => 8443, cert => CertDer, key => Key,
        verify => verify_peer, cacerts => CaCerts
    },
    router => Router
}).
```

A client without a certificate, or with one your CAs did not sign, is
refused during the handshake, on HTTP/1.1, HTTP/2 and HTTP/3 alike. Your
handlers never see it. A listener that asks for certificates without
`cacerts` does not start.

## Read the certificate in a handler

`livery_req:tls/1` tells you what the handshake established:

```erlang
handle(Req) ->
    case livery_req:tls(Req) of
        #{verified := true, subject := Subject, san := San} ->
            Who = proplists:get_value(<<"CN">>, Subject),
            livery_resp:text(200, [<<"hello ">>, Who]);
        #{verified := false} ->
            livery_resp:text(401, <<"client certificate required">>);
        undefined ->
            livery_resp:text(400, <<"use https">>)
    end.
```

The map holds:

- `verified`: `true` when the client presented a certificate.
- `cert`: the client's certificate, DER-encoded, if you need to decode it
  yourself with `public_key:pkix_decode_cert/2`.
- `subject`: the subject's attributes in certificate order, such as
  `[{<<"O">>, <<"Acme">>}, {<<"CN">>, <<"alice">>}]`.
- `san`: the subject alternative names, as `{dns, Bin}`, `{email, Bin}`,
  `{uri, Bin}` (a SPIFFE ID, for example) and `{ip, Address}`.

## Map the certificate to an identity in middleware

Most of the time you want this once, before routing:

```erlang
-module(mtls_identity).
-behaviour(livery_middleware).
-export([call/3]).

call(Req, Next, Allowed) ->
    case livery_req:tls(Req) of
        #{verified := true, san := San} ->
            case [Id || {uri, Id} <- San, lists:member(Id, Allowed)] of
                [Id | _] -> Next(livery_req:set_meta(identity, Id, Req));
                [] -> livery_resp:text(403, <<"unknown client">>)
            end;
        _ ->
            livery_resp:text(401, <<"client certificate required">>)
    end.
```

## Notes

- Over TLS without `verify => verify_peer`, the request carries
  `#{verified => false}`. On plain HTTP it carries `undefined`.
- A certificate on the request has always been checked: TLS only lets a
  client send one the server asked for, and Livery asks only when it
  checks the chain against `cacerts`.
- With `verify => verify_peer`, Livery is in charge of client
  authentication: a listener whose `ssl_opts` (or `quic_opts` on HTTP/3)
  also sets `verify`, `fail_if_no_peer_cert`, `cacerts`, `cacertfile`,
  `partial_chain`, `verify_fun` or `require_client_cert` refuses to start
  with `{error, {conflicting_tls_opts, Keys}}`, since those would replace
  Livery's checks without warning. To check revocation, add `crl_check`
  and `crl_cache` to `ssl_opts`; they can only make the check stricter.
- The certificate is read once per request from the connection. On
  listeners without `verify_peer` there is none to decode, so the cost
  is a single call.

## See also

- How-to: [Serve several certificates by hostname (SNI)](serve-multiple-certs-sni.md)
- How-to: [Write custom middleware](custom-middleware.md)
- Reference: `livery_tls`, `livery_req`, `livery_service`
