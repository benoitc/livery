# Adapters

This page explains what an adapter is and why Livery keeps it thin. You
rarely write one, but understanding the boundary tells you where each
kind of work belongs. An adapter is the thin translator between a wire
library and Livery's request/response model. It is the only part of
Livery that knows there is a socket. Everything above it (the router, the
middleware, your handlers) works in terms of request and response values,
and the adapter turns those into the bytes a particular protocol expects.

Because the adapter owns so little, the same handler runs unchanged over
HTTP/1.1, HTTP/2, and HTTP/3, and over an in-memory test harness with no
socket at all.

## When you would write one

Almost never: the four shipped adapters cover HTTP/1.1, HTTP/2, HTTP/3,
and in-memory testing. **You write an adapter when** you want Livery's
handler model over a transport it does not speak yet, for example a
different HTTP implementation, an RPC over a message bus, or a bespoke
test harness. If you find yourself reaching for one to add buffering,
routing, or protocol logic, that work belongs upstream in the wire
library or downstream in a middleware instead.

## The behaviour

An adapter implements the `livery_adapter` behaviour:

```erlang
-callback start(Name, ListenSpec, Opts) -> {ok, Listener}.
-callback stop(Listener) -> ok.
-callback send_headers(Stream, Status, Headers, SendOpts) -> SendResult.
-callback send_data(Stream, IoData, SendOpts) -> SendResult.
-callback send_trailers(Stream, Trailers) -> SendResult.
-callback reset(Stream, Reason) -> ok.
-callback peer_info(Stream) -> #{peer, tls, alpn}.
-callback capabilities(Listener) -> #{trailers, extended_connect, datagrams, capsules}.
```

`SendOpts` is `#{end_stream => boolean(), flush => boolean()}`.
`SendResult` is `ok | {error, closed | flow | term()}`. There is an
optional `send_full/5` an adapter may export to coalesce headers and body
into one write; `livery:emit/3` uses it when present.

## Adapters that ship

| Adapter | Serves | Backed by |
|---|---|---|
| `livery_test_adapter` | in-memory | ETS, no socket |
| `livery_h1` | HTTP/1.1 | `h1` |
| `livery_h2` | HTTP/2 | `h2` |
| `livery_h3` | HTTP/3 | `quic` (`quic_h3` subsystem) |

The test adapter is the one to read first: it is the smallest complete
implementation, and the parity SUITE drives one handler set through every
adapter to prove they behave the same.

## What an adapter is not

- **Not a state machine.** Framing, header compression, flow control, and
  TLS belong to the wire library.
- **Not a buffer.** The body reader buffers; the adapter does not.
- **Not a router.** Routing happens in middleware, after the request
  reaches the worker.

## How an adapter is wired

On a new request the adapter builds a request value, asks
`livery_req_sup:start_request/1` to spawn the per-request worker, and
feeds the body in as `{livery_body, Ref, _}` messages:

```erlang
{ok, Worker} = livery_req_sup:start_request(#{
    adapter => ?MODULE, stream => Stream, req => Req,
    stack => Stack, handler => Handler
}),
Worker ! {livery_body, BodyRef, {data, Chunk}},
Worker ! {livery_body, BodyRef, eof}.
```

The worker runs the middleware and handler, then drives the response back
out through `livery:emit/3`, which calls your `send_headers/4`,
`send_data/3`, and `send_trailers/2`. So the adapter is two halves: turn
inbound wire events into the body protocol, and implement the `send_*`
callbacks for the outbound side.

`examples/livery_example_adapter.erl` is a complete, readable adapter that
does exactly this, capturing the response in ETS instead of a socket so
the wiring is easy to follow. Section 10 of
[Build a complete service](../tutorials/build-a-complete-service.md) walks
it. To grow it into a real transport, keep the callbacks, replace the ETS
sink with socket writes, translate your wire's body events into
`{livery_body, Ref, _}` messages, then add a group to
`test/livery_parity_SUITE.erl` so it is held to the same behaviour as the
others.

## Capability gating

A handler can branch on what the arriving protocol supports:

```erlang
Adapter = livery_req:adapter(Req),
case Adapter:capabilities(livery_req:stream(Req)) of
    #{trailers := true} ->
        livery_resp:with_trailers([{<<"x-fin">>, <<"1">>}], Resp);
    _ ->
        Resp
end.
```

Call `capabilities/1` on the concrete adapter module the request arrived
on (`livery_req:adapter/1`), not on `livery_adapter`. `trailers` and
`extended_connect` are protocol-specific; `datagrams` and `capsules`
apply to WebTransport on H3.

## Listen address

Every adapter takes the same `ip => inet:ip_address()` and
`inet6 => boolean()` listen options, translated to the wire library by
`livery_inet:socket_addr_opts/1`. See
[Bind to an address or IPv6](../guides/bind-listen-address.md).

## The client adapter, its dual

The same idea runs outbound. `livery_client_adapter` is the dual of this
behaviour: it owns the wire for an outgoing request, while the client's
layers (timeout, retry, circuit breaker) own the policy above it. The
default `livery_client_hackney` covers HTTP/1.1, HTTP/2, and HTTP/3. When
the target is a pool of replicas, a `balance` layer spreads requests
across them and `livery_client_discover` resolves the endpoint set. See
[Make outbound HTTP requests](../guides/make-http-requests.md) and
[Load-balance outbound requests](../guides/load-balance-requests.md).

## See also

- Concept: [Architecture](architecture.md)
- Concept: [Request lifecycle](request-lifecycle.md)
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Guide: [Bind to an address or IPv6](../guides/bind-listen-address.md)
- Reference: `livery_adapter`, `livery_test_adapter`
