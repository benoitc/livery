# Architecture

This page explains the overall shape of Livery: how the pieces fit
together and why they are split the way they are. Read it when you
want a mental model of where your code runs before you dive into any
single part. Livery is one OTP application that sits on top of three
external wire libraries and exposes one developer-facing surface, so
you write your handlers once and they serve every protocol.

```
                 ┌─────────────────────┐
                 │       livery        │
                 │  service runtime    │
                 └──────────┬──────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   livery_h1           livery_h2           livery_h3
    over h1            over h2           over quic_h3
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                     router + middleware
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
      REST               MCP              streaming/SSE
    OpenAPI          Streamable HTTP       WebSocket, WT
```

## The two layers

**Wire layer.** `h1`, `h2`, `quic`, `ws` are independent hex
packages. They own framing, HPACK, QPACK, QUIC state, TLS, flow
control, and the WebSocket codec. Livery does not reimplement any
of this.

**Developer layer.** Livery owns the request value, response
value, router, middleware, extractors, body reader, per-request
process, service runtime, observability, auth, OpenAPI, MCP, and
WebTransport integration.

## One app, three adapters

`livery:start_service/1` brings up H3 on UDP, H2 on TLS,
and H1 on TCP under one supervisor. All three feed into the same
router and the same middleware stack. Responses on H1 and H2 carry
`Alt-Svc: h3=":443"` so clients can race and upgrade.

Adapters are translators:

| Adapter callback | Job |
|---|---|
| `start/3` | hand a listener spec to the wire library |
| `send_headers/4` | emit status + headers (with `end_stream` hint) |
| `send_data/3` | emit body bytes |
| `send_trailers/2` | emit trailers and close the send half |
| `reset/2` | abort a stream with a protocol-specific reason |
| `peer_info/1` | report peer address, TLS info, ALPN |
| `capabilities/1` | report `trailers`, `extended_connect`, `datagrams`, `capsules` |

No state machine, no buffering, no framing. The adapter answers
"how do I make this engine emit headers".

## Per-request process

For each inbound request the adapter spawns a short-lived worker via
`livery_req_sup:start_request/1`. The worker:

1. Owns the body reference and receives `{livery_body, Ref, _}`
   messages from the adapter.
2. Runs the middleware stack and handler via `livery:dispatch/3`.
3. Walks the response variant via `livery:emit/3` into the
   adapter's `send_*` callbacks.
4. Exits when done.

The listener process is never blocked on a slow handler: it handed the
request to its own worker and moved on. Crashes are mapped to `500` and
the worker exits normally. The [request lifecycle](request-lifecycle.md)
page follows this path step by step.

## What this enables

- Handlers see one request value regardless of protocol.
- Bug fixes in framing or congestion control land in `h1`/`h2`/`quic`
  as dep bumps, not Livery patches.
- A future protocol needs only a new adapter implementing the same
  callbacks; the router, middleware, and handlers do not change.

## See also

- [Adapters](adapters.md) - the behaviour in detail
- [Request lifecycle](request-lifecycle.md) - message flow
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Long-form: [design.md](../design.md)
