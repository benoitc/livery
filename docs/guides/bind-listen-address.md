# How to bind to a specific address or IPv6

## Problem

By default a listener binds the IPv4 wildcard, accepting connections
on every interface. You want to pin it to one address, or serve over
IPv6.

## Solution

Every listener accepts two options, on `start_service/1`,
`start_listener/2`, and each adapter's `start/1`:

- `ip => inet:ip_address()` — the bind address. An IPv6 8-tuple
  selects the IPv6 family automatically.
- `inet6 => true` — bind the IPv6 wildcard (`::`) when you do not
  want to name a specific address.

They work the same across all three protocols (HTTP/1.1, HTTP/2,
and HTTP/3 over QUIC).

### What the protocol keys mean

Each key in `start_service/1` is one adapter serving one protocol:

| Key | Protocol | Transport |
|---|---|---|
| `http` | HTTP/1.1 | cleartext TCP |
| `https` | HTTP/2 | TLS (needs `cert`/`key`) |
| `http3` | HTTP/3 | QUIC (needs `cert`/`key`) |

So `http` is HTTP/1.1 only, *not* HTTP/1.1 plus HTTP/2. To serve more
than one protocol, list more than one key, which is what the examples
below do. (The transport is the default per key; `http` and `https` also
accept a `transport` override if you ever want HTTP/1.1 over TLS or
cleartext HTTP/2.) Add `alt_svc => advertise` to the service map to put
an `Alt-Svc` header on the H1 and H2 responses so capable clients can
upgrade to H3.

### IPv6 on every protocol

```erlang
{ok, Pid} = livery:start_service(#{
    http  => #{port => 8080, inet6 => true},
    https => #{port => 8443, inet6 => true, cert => Cert, key => Key},
    http3 => #{port => 8443, inet6 => true, cert => Cert, key => Key},
    router => Router
}).
```

### A specific address on every protocol

To bind all three adapters to one address, put the same `ip` in each
protocol's map. The three listeners share the one `router` (and
middleware); only the bind address and ports differ.

```erlang
Addr = {192, 168, 1, 10},          %% an IPv6 8-tuple works the same way
{ok, Pid} = livery:start_service(#{
    http  => #{port => 8080, ip => Addr},
    https => #{port => 8443, ip => Addr, cert => Cert, key => Key},
    http3 => #{port => 8443, ip => Addr, cert => Cert, key => Key},
    router => Router
}).
```

HTTP/2 (over TLS) and HTTP/3 (over QUIC) can share the same port number
because one is TCP and the other is UDP; HTTP/1.1 is cleartext on its
own port. Each map also accepts `inet6 => true` instead of a specific
`ip` to bind the IPv6 wildcard.

### A specific address on a single listener

```erlang
%% IPv4 loopback only
{ok, _} = livery:start_listener(livery_h1, #{
    port => 8080,
    ip => {127, 0, 0, 1},
    stack => Stack,
    handler => Handler
}).

%% A specific IPv6 address (family inferred from the 8-tuple)
{ok, _} = livery:start_listener(livery_h3, #{
    port => 8443,
    ip => {0, 0, 0, 0, 0, 0, 0, 1},
    cert => Cert, key => Key,
    stack => Stack, handler => Handler
}).
```

### What `handler` and `stack` are

A single-protocol listener takes two more options that say what to run
for each request:

- `handler` is the function that turns a request into a response: a
  `fun((Req) -> Resp)`, or a `{Module, Function}` pair. Usually you do
  not write this by hand. You compile routes and let
  `livery:router_handler/1` build it for you:

  ```erlang
  Router  = livery_router:compile([{<<"GET">>, <<"/">>, {hello, index}}]),
  Handler = livery:router_handler(Router).
  ```

  `livery:start_service/1` does this step for you, which is why its
  examples above pass `router => Router` instead of a `handler`. With a
  single adapter's `start/1` you pass the `handler` yourself. See
  [Routing](../concepts/routing.md).

- `stack` is the middleware stack: an ordered list of cross-cutting
  steps (request id, logging, body limit, auth) that run around the
  handler. `[]` means none. For example:

  ```erlang
  Stack = [{livery_request_id, undefined}, {livery_access_log, #{}}].
  ```

  See [The middleware pipeline](../concepts/middleware-pipeline.md).

The bind options (`ip`, `inet6`) are independent of these: they decide
*where* the listener accepts connections, while `handler` and `stack`
decide *what happens* to each request.

## Dual-stack vs IPv6-only

Binding `inet6` gives you whatever the OS default for v6 sockets is.
On most systems that is dual-stack (the socket also accepts IPv4 via
v4-mapped addresses); some default to v6-only. To be explicit, pass
the underlying socket option through the adapter's lower-level opts:

- HTTP/1.1 and HTTP/2: `ssl_opts => [{ipv6_v6only, true}]` (TLS) or
  rely on the TCP listener's `inet6` family for cleartext.
- HTTP/3: `quic_opts => #{extra_socket_opts => [{ipv6_v6only, true}]}`.

To serve both families predictably, start one listener per family on
the same port.

## WebSockets and WebTransport

There is nothing extra to configure. WebSockets (HTTP Upgrade on
HTTP/1.1, extended CONNECT on HTTP/2 and HTTP/3) and WebTransport
upgrade in place on the adapter's existing stream, so they inherit the
listener's bind address and family. Bind the listener to IPv6 and a
`wss://[::1]/...` client connects over IPv6.

## Notes

- `ip` and `inet6` are translated to the wire libraries the same way
  everywhere by `livery_inet:socket_addr_opts/1`: an IPv6 `ip` tuple
  or `inet6 => true` selects the `inet6` family, and `ip` sets the
  bind address.
- For HTTP/3 the options fold into the QUIC listener's
  `extra_socket_opts`; any `extra_socket_opts` you set yourself are
  preserved.
- `livery_service:which_listeners/1` reports the bound ports.

## See also

- Concept: [Adapters](../concepts/adapters.md)
- Reference: `livery`, `livery_service`
