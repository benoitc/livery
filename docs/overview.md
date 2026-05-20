# Overview

Livery is a BEAM-native web framework that serves one handler set
over HTTP/1.1, HTTP/2, and HTTP/3 from a single service runtime,
with WebSocket, WebTransport, Server-Sent Events, OpenAPI, MCP, and
OpenTelemetry-style observability as built-in modules.

It is written in the spirit of Axum + Tower + Hyper on the BEAM.

## When to use Livery

- You are building a REST or GraphQL API and want HTTP/2 and HTTP/3
  out of the box without composing several libraries.
- You need browser-friendly streaming (SSE) or WebSocket on H1, H2,
  and H3 from the same handler.
- You are building an agent or tool server and want MCP Streamable
  HTTP on the main listener, not a sidecar.
- You already run Erlang/OTP and want to stop assembling a stack out
  of Cowboy plus a dozen adjunct libraries.
- You have used Axum, Fastify, or FastAPI and expect the same
  ergonomics.

## When not to use Livery

- You only need a static file server. Cowboy or `httpd` is simpler.
- You need a battle-tested 1.0 today. Livery is still under heavy
  rewrite; the H1/H2/H3 wire adapters land in Phases 2 to 4. Until
  then only the test adapter is wired.

## Design principles

1. **Protocol neutrality.** The handler does not know whether it is
   talking H1, H2, or H3. The request value is the same. The
   response value is the same. Capability flags surface where
   features differ.
2. **Race H3, fall back to H2, fall back to H1.** One service runs
   all three on the same host. Alt-Svc advertises H3 so clients
   upgrade on the next request.
3. **Thin adapters.** Each protocol adapter is a translator, not a
   state machine. Flow control, HPACK, QPACK, QUIC, TLS, framing
   all live upstream in the wire libraries.
4. **Axum + Tower ergonomics.** Plain function handlers. Extractors
   for typed input. An ordered middleware stack with request and
   response transformation.
5. **Data, not processes.** Requests and responses are immutable
   values. Middleware transforms values. Processes only exist where
   they earn their keep.
6. **Backpressure by default.** Streaming bodies read on demand. A
   stalled client applies backpressure to the handler, not the other
   way around.
7. **Composable integrations.** Auth, MCP, OpenAPI, WebTransport,
   instrumentation are modules in the same app, engaged only when
   the user mounts them. They share the adapter stack and middleware
   pipeline.
8. **No secret sauce on the wire.** Anything visible on the network
   is the wire libraries' problem. If something is wrong at the
   frame or stream level, the fix lands there, not in Livery.

## What is in the box

| Layer | Module(s) |
|---|---|
| Public facade | `livery` |
| Request value | `livery_req`, `livery_ext` |
| Response builders | `livery_resp` |
| Router | `livery_router` |
| Middleware | `livery_middleware`, built-ins |
| Body reader | `livery_body` |
| Adapter behaviour | `livery_adapter` |
| In-memory driver | `livery_test_adapter` |
| Per-request worker | `livery_req_proc`, `livery_req_sup` |

Phase 2 onward adds `livery_h1`, `livery_h2`, `livery_h3`,
`livery_service`, `livery_ws`, `livery_sse`, `livery_drain`,
`livery_auth*`, `livery_openapi*`, `livery_mcp*`, `livery_instrument_*`.

## How Livery differs from Cowboy

| | Cowboy | Livery |
|---|---|---|
| HTTP versions | H1, H2 | H1, H2, H3 |
| Wire layer | in-tree | sibling libraries |
| Middleware shape | callback per handler family | one `call(Req, Next, State)` |
| Extractors | manual `cowboy_req:*` threading | `livery_ext:json/1`, `query/2`, etc. |
| Streaming | `cowboy_loop` + `info/3` | producer fun with `Emit`, free to `receive` |
| OpenAPI | external | built-in (Phase 9) |
| MCP | second listener | first-class endpoint type (Phase 10) |
| Alt-Svc upgrade | not provided | built into `livery_service` (Phase 4) |

See [Migrate from Cowboy](guides/migrate-from-cowboy.md) for the
full mapping table.
