# Architecture

This page explains the overall shape of Livery: how the pieces fit
together and why they are split the way they are. Read it when you
want a picture of where your code runs before you look at any single
part. Livery is one OTP application on top of external wire libraries
(three for HTTP, plus `ws` for WebSocket), with one API for you to
write against, so you write your
handlers once and they serve every protocol.

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
packages. They handle framing, HPACK, QPACK, QUIC state, TLS, flow
control, and the WebSocket codec. Livery does not reimplement any
of this.

**Developer layer.** Livery provides the request value, response
value, router, middleware, extractors, body reader, per-request
process, service runtime, observability, auth, OpenAPI, MCP, and
WebTransport integration.

## One app, three adapters

`livery:start_service/1` brings up H3 on UDP, H2 on TLS,
and H1 on TCP together, under one `livery_service` process. All three
feed into the same router and the same middleware stack. Responses on H1 and H2 carry
`Alt-Svc: h3=":443"` so clients can switch to H3 on their next
request.

Adapters only translate between Livery and the wire library:

| Adapter callback | Job |
|---|---|
| `start/3` | hand a listener spec to the wire library |
| `send_headers/4` | send status and headers (with an `end_stream` hint) |
| `send_data/3` | send body bytes |
| `send_trailers/2` | send trailers and close the sending side of the stream |
| `reset/2` | abort a stream with a protocol-specific reason |
| `peer_info/1` | report peer address, TLS info, ALPN |
| `capabilities/1` | report `trailers`, `extended_connect`, `datagrams`, `capsules`, `informational` |

No state machine, no buffering, no framing. The adapter answers one
question: how do I make this library send headers?

## Per-request process

Each wire library runs the adapter in a process of its own for every
request. That process becomes the request's translator
(`livery_translator`): it starts a short-lived worker through
`livery_req_sup:start_request/1`, then turns the library's body events
into messages for it until the worker exits. The worker:

1. Owns the body reference and receives `{livery_body, Ref, _}`
   messages from the adapter.
2. Runs the middleware stack and handler via `livery:dispatch/3`.
3. Passes the response to `livery:emit/3`, which sends it through
   the adapter's `send_*` callbacks according to its body type.
4. Exits when done.

The listener process is never blocked on a slow handler: it handed the
request to its own worker and moved on. A crash becomes a `500` and
the worker exits normally. The [request lifecycle](request-lifecycle.md)
page follows this path step by step.

## What this enables

- Handlers see one request value regardless of protocol.
- Fixes to framing or congestion control go into `h1`/`h2`/`quic`;
  Livery picks them up by updating the dependency, not by patching
  its own code.
- A future protocol needs only a new adapter implementing the same
  callbacks; the router, middleware, and handlers do not change.

## Design decisions

Livery was announced, with 0.2.0, around five rules:

1. **Values, not handles.** `Req` and `Resp` are plain records, easy to
   pass between processes and to test.
2. **Middleware is a continuation.** `call(Req, Next, State) -> Resp`,
   where `Next` is the rest of the pipeline. To wrap it in a
   try/catch, a timeout or a span, you call it inside your own code.
3. **Protocol neutrality.** A handler never knows whether it is on H1,
   H2 or H3; differences show up only through capabilities.
4. **Thin adapters.** The wire libraries own the protocols.
5. **The same model outbound.** The client is the middleware model
   turned around.

The choices below follow from them.

**One process per request.** Your handler may block, `receive`, or
crash: it runs in its own worker, so a slow handler never stalls the
listener and a crash becomes a `500` without touching anything else.

**The translator.** Each wire library already starts a process per
request; that process becomes the request's translator. It turns the
library's events into the `{livery_body, Ref, _}` messages the body
reader understands, so neither your handler nor `livery_body` ever sees
a protocol-specific message (rule 3). It enforces `max_body` before the
bytes reach the worker's mailbox, gives flow-control credit back to the
library as the handler reads (rule 4), and notices a
disconnect while the handler is busy in your code. Keeping all of that
out of the worker also means a handler free to `receive` cannot swallow
a wire message by accident. `livery_translator` is shared by the three
adapters, so body limits and disconnects behave the same everywhere.

**An admission counter, not a supervisor.** `livery_req_sup` is a
`gen_server` that counts requests in flight. Workers are started in the
calling process with `proc_lib:spawn`, so starting one never has to
wait its turn behind a single process, and the counter goes down on the
worker's `DOWN`, so even a killed worker is accounted for.

**Who owns what.** Listeners belong to the wire libraries, under their
own supervisors. A service belongs to the application that starts it:
put `livery:start_service/1` in your supervision tree. `livery_sup`
only holds what the whole node shares: the admission counter and the
stores below.

**Optional features are optional callbacks.** An adapter offers
`send_full/5`, `send_informational/3`, `accept_ws/4` or `accept_wt/4` by
implementing it; Livery checks with `livery_adapter:implements/3`, never
with a list of adapters, so an adapter written outside Livery gets Early
Hints, WebSocket and WebTransport the same way (rule 3). An upgrade
answers status `101` on every protocol, Livery's way of saying "this
stream is now a WebSocket" whatever the protocol, even though HTTP/2 and HTTP/3 send
`200` to the extended CONNECT.

**What the test adapter proves.** `livery_test_adapter` runs your stack
in the calling process and captures the response value (rule 1). The
parity suite compares those values across every adapter; the runtime
limits (`max_body`, disconnects, the worker itself) are tested in each
adapter's own suite.

**The client.** `livery_client` is a stack of layers around an adapter
(rule 5). One step is fixed at the end, outside the layers: the check
that credentials only go to the origins they are for, and the DPoP
proof, both of which must see the final URL whatever order you stack
the layers in. hackney is the outbound wire library; it sits on the
same `h2` and `quic` libraries as the server.

**Shared stores.** Rate limits, circuit breakers, load-balancing state,
token caches and single-use values live in ETS tables, each owned by a
process under `livery_sup` and read directly by the request that needs
them, so no single process sits on the request path.

## See also

- [Adapters](adapters.md) - the behaviour in detail
- [Request lifecycle](request-lifecycle.md) - message flow
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Long-form: [design.md](../design.md)
