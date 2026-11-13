# Overview

Livery is a web framework for Erlang/OTP. It serves one set of
handlers over HTTP/1.1, HTTP/2, and HTTP/3 from a single service, and
WebSocket, WebTransport, Server-Sent Events, OpenAPI, MCP, and
OpenTelemetry-style observability come as modules in the same package.

It follows the ideas of Rust's Axum, Tower and Hyper, on the BEAM.

## When to use Livery

- You are building a REST or GraphQL API and want HTTP/2 and HTTP/3
  without putting several libraries together yourself.
- You need streaming that browsers can read (SSE), or WebSocket, on
  H1, H2, and H3 from the same handler.
- You are building an agent or tool server and want MCP Streamable
  HTTP or an A2A agent on the main listener, not on a separate server
  next to it.
- You already run Erlang/OTP and want to stop building on Cowboy plus
  a dozen other libraries.
- You have used Axum, Fastify, or FastAPI and expect to work the same
  way.

## When not to use Livery

- You only need a static file server. Cowboy or `httpd` is simpler.
- You need a 1.0 with a long track record. Livery is young: its API
  still moves between minor releases, and the CHANGELOG says what
  changed each time.

## Design principles

1. **Protocol neutrality.** The handler does not know whether it is
   talking H1, H2, or H3. The request value is the same. The
   response value is the same. Where the protocols differ in what
   they can do, capability flags tell the handler.
2. **H3 first, then H2, then H1.** One service runs all three on the
   same host. The Alt-Svc header tells clients H3 is there, so they
   can switch to it on their next request.
3. **Thin adapters.** Each protocol adapter only translates; it does
   not run the protocol itself. Flow control, HPACK, QPACK, QUIC, TLS
   and framing all live in the wire libraries.
4. **Work like Axum and Tower.** Handlers are plain functions.
   Extractors give you typed input. Middleware is an ordered stack
   that can change the request on the way in and the response on the
   way out.
5. **Data, not processes.** Requests and responses are immutable
   values. Middleware changes values. Livery starts a process only
   where one is needed.
6. **Backpressure by default.** A streaming body is read only when
   the handler asks for more. A client that stalls holds the handler
   back, not the other way around.
7. **Features you add when you need them.** Auth, MCP, A2A, OpenAPI,
   WebTransport and instrumentation are modules in the same
   application, and do nothing until you mount them. They use the
   same adapters and the same middleware pipeline.
8. **Nothing of Livery's own on the wire.** What goes over the
   network is the wire libraries' job. If something is wrong at the
   frame or stream level, the fix goes there, not in Livery.

## What is in the box

| Layer | Module(s) |
|---|---|
| Public API | `livery` |
| Request value | `livery_req`, `livery_ext` |
| Response builders | `livery_resp` |
| Router | `livery_router` |
| Middleware | `livery_middleware`, built-ins |
| Body reader | `livery_body` |
| Adapter behaviour | `livery_adapter` |
| In-memory adapter | `livery_test_adapter` |
| Per-request worker | `livery_req_proc`, `livery_req_sup` |

The wire adapters and service runtime are `livery_h1`, `livery_h2`,
`livery_h3`, and `livery_service`; streaming, upgrades, shutdown,
auth, OpenAPI, MCP, A2A, and observability are `livery_ws`,
`livery_wt`, `livery_drain`, `livery_auth*`, `livery_openapi*`,
`livery_mcp`, `livery_a2a`, and `livery_instrument_*`. SSE and NDJSON are builders on
`livery_resp`.

## How Livery differs from Cowboy

| | Cowboy | Livery |
|---|---|---|
| HTTP versions | H1, H2 | H1, H2, H3 |
| Protocol code | built in | separate libraries |
| Middleware shape | a different callback for each kind of handler | one `call(Req, Next, State)` |
| Extractors | pass `Req` through `cowboy_req:*` calls by hand | `livery_ext:json/1`, `query/2`, etc. |
| Streaming | `cowboy_loop` + `info/3` | producer fun with `Emit`, free to `receive` |
| OpenAPI | external | built-in |
| MCP | second listener | an endpoint on the main listener |
| A2A | second listener | an endpoint on the main listener |
| Alt-Svc upgrade | not provided | built into `livery_service` |

See [Migrate from Cowboy](guides/migrate-from-cowboy.md) for the
full mapping table.
