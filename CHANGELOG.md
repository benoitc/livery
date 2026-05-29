# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Cowboy cutover validation. `examples/livery_example_migration.erl`
  expresses the common Cowboy patterns (plain handler, REST resource,
  SSE, a `cowboy_loop`-style streaming endpoint, WebSocket echo) in
  Livery, and `test/livery_cowboy_parity_SUITE.erl` runs that handler set
  behind both a live Cowboy listener and Livery, diffing the observable
  behaviour over H1, then drives the same Livery handlers over H2 and H3.

## [0.1.0] - 2026-05-26

First public release. Livery is a BEAM-native web framework that serves
one handler set over HTTP/1.1, HTTP/2, and HTTP/3 from a single service
runtime, in the spirit of Axum + Tower + Hyper. This is an early (0.x)
release; the framework is still under active development.

### Core

- Multi-protocol service runtime (`livery:start_service/1`) that brings
  H3 (UDP), H2 (TLS), and H1 (TCP) up together under one router and
  middleware stack and advertises `Alt-Svc` for H3. Single-protocol
  listeners via `livery:start_listener/2`.
- Thin H1/H2/H3 adapters over the sibling wire libraries (`h1`, `h2`,
  `quic`); externally observable behaviour is locked across all adapters
  by a parity test suite.
- Per-request worker model (`livery_req_proc`) with a per-stream
  translator that forwards wire events, so handlers may block and
  receive.
- Value-based Tower/Axum middleware (`call(Req, Next, State) -> Resp`),
  with global and per-route stacks.
- Immutable request/response values (`livery_req`, `livery_resp`) and a
  radix-trie router (`livery_router`).
- Response body variants: full, chunked, SSE, file, empty, and upgrade.
- Graceful shutdown via `livery_drain` and cancel-on-disconnect across
  H1/H2/H3.

### Protocols and streaming

- WebSocket over H1, H2, and H3.
- WebTransport upgrade bridge over H3.
- Server-Sent Events and file responses streamed over every adapter.
- MCP Streamable HTTP handler over `barrel_mcp` 2.0.

### Middleware and helpers

- CORS (`livery_cors`) and security headers (`livery_security_headers`).
- Response compression (`livery_compress`) over a pluggable
  `livery_codec` registry, with gzip and deflate built in.
- Multipart and streaming form-body parsing (`livery_multipart`,
  `livery_ext:read_form/1,2`).
- Concurrency-limit load shedding (`livery_concurrency`) and per-key
  rate limiting (`livery_ratelimit`).
- HTTP caching: automatic ETag and conditional GET (`livery_etag`) plus
  `livery_resp:with_etag/2` and `with_cache_control/2`.
- Static-directory serving (`livery_static`) with MIME by extension,
  weak ETag, Range, directory index, and strict path confinement.
- Health and readiness endpoints (`livery_health`) and a Prometheus
  `/metrics` handler (`livery_metrics`).

### Auth and API tooling

- Signed session cookies and RFC 7662 token introspection.
- Bearer middleware with OIDC discovery and JWKS fetch, cache, and
  rotation.
- OpenAPI request validation with inline Redoc and Swagger UI handlers.

### Observability

- OpenTelemetry-style tracing and HTTP server metrics over the
  `instrument` library, with a logger bridge that carries trace context
  into log events.
- Metrics middleware (`livery_instrument_metrics`) is best-effort and
  resolves instruments from the `instrument` registry on each request, so
  it never fails a request and self-heals after a registry restart
  (requires `instrument` 1.1.2).

### Notes

- In the bundled in-VM benchmark harness, H3 throughput is bounded by the
  QUIC round trip because the client and server share one BEAM. Measure
  H3 with an external native QUIC client.

[0.1.0]: https://github.com/benoitc/livery/releases/tag/v0.1.0
