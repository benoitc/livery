# How to bind to a specific address or IPv6

## Problem

By default a listener binds the IPv4 wildcard, accepting connections
on every interface. You want to pin it to one address, or serve over
IPv6.

## Solution

Every listener accepts two options, on `start_service/1`,
`start_listener/2`, and each adapter's `start/1`:

- `ip => inet:ip_address()` - the bind address. An IPv6 8-tuple
  selects the IPv6 family automatically.
- `inet6 => true` - bind the IPv6 wildcard (`::`) when you do not
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
below do.

The transport shown is the default per key, but `http` and `https` take
a `transport` override. The useful one is **h2c**, HTTP/2 over cleartext
(no TLS): it is the `https` adapter with `transport => tcp` and no
`cert`/`key`.

```erlang
%% HTTP/2 cleartext (h2c) on a specific address, no certificates
https => #{port => 8080, ip => Addr, transport => tcp}
```

You can likewise run HTTP/1.1 over TLS by giving the `http` map a
`transport => ssl` with `cert`/`key`. Add `alt_svc => advertise` to the
service map to put an `Alt-Svc` header on the H1 and H2 responses so
capable clients can upgrade to H3.

### Starting an adapter: on its own, or as a service

There are two ways to bring an adapter up, and the bind options work the
same in both.

**On its own**, with `livery:start_listener/2`. You pass the adapter
module, its options, and the `stack` and `handler` yourself. You get back
the listener handle and you own its lifecycle:

```erlang
{ok, Ref} = livery:start_listener(livery_h1, #{
    port => 8080,
    ip => {127, 0, 0, 1},
    stack => Stack,
    handler => Handler
}),
%% ... later ...
ok = livery:stop_listener({livery_h1, Ref}).
```

**As a service**, with `livery:start_service/1`. The service starts the
adapters for you, one per protocol key, sharing one `router` (or
`handler`) and one middleware stack, and stops them together. It is a
supervising process, so you also get `livery_service:which_listeners/1`
and graceful `livery:drain/2`. This is the usual choice.

The map can hold any subset of the keys, including just one, so
`start_service/1` is also the managed way to run a *single* adapter. The
difference from `start_listener/2` is not the number of adapters: it is
that the service supervises them and shares the router and stack, whereas
`start_listener/2` is a bare listener whose handle you hold yourself.

```erlang
%% A single adapter (H1), but managed as a service:
{ok, Pid} = livery:start_service(#{
    http   => #{port => 8080, ip => {127, 0, 0, 1}},
    router => Router
}).
```

### Can I run several adapters?

Yes, in two senses.

- **Several protocols at once.** A single service already runs more than
  one adapter: give it `http`, `https`, and `http3` and it brings up H1,
  H2, and H3 together (the examples below do this).
- **Several listeners of the same kind.** To bind, say, HTTP/1.1 on two
  different addresses, call `start_listener/2` once per listener and keep
  each handle. Each listener is independent.

```erlang
{ok, Lan} = livery:start_listener(livery_h1, #{
    port => 8080, ip => {10, 0, 0, 5}, stack => Stack, handler => Handler
}),
{ok, Local} = livery:start_listener(livery_h1, #{
    port => 8080, ip => {127, 0, 0, 1}, stack => Stack, handler => Handler
}).
```

A `start_service/1` map holds one entry per protocol, so for several
listeners of the same protocol use `start_listener/2` (or run more than
one service).

### Custom adapters

`start_service/1` and `livery:start_listener/2` manage only the three
built-in adapters: `start_service/1` maps `http`/`https`/`http3` to
`livery_h1`/`livery_h2`/`livery_h3`, and `start_listener/2` accepts those
three modules (anything else returns `{error, unknown_adapter}`).

A custom adapter, any module implementing the `livery_adapter` behaviour,
is not registered with either entry point. You start it through its own
start function, and it owns its listener and lifecycle:

```erlang
%% A custom adapter exposes its own start; it is not passed to
%% livery:start_listener/2.
{ok, Listener} = my_adapter:start(#{
    port => 8080,
    ip => {127, 0, 0, 1},
    stack => Stack,
    handler => Handler
}).
```

The bind options are a convention, not magic: a custom adapter honours
`ip`/`inet6` by running them through `livery_inet:socket_addr_opts/1`
(the same helper the built-ins use) and handing the result to its wire
library. See [Adapters](../concepts/adapters.md) for the behaviour and
`examples/livery_example_adapter.erl` for a complete, runnable one.

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
