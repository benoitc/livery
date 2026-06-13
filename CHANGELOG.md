# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-06-14

Maintenance release: dependency updates.

### Changed

- Bump `h2` 0.9.0 -> 0.10.1, `hackney` 4.3.0 -> 4.4.0, and `barrel_mcp`
  2.2.2 -> 2.2.3.
- Require the wire dependencies (`h1`, `h2`, `quic`, `ws`, `instrument`,
  `webtransport`, `hackney`, `barrel_mcp`) with `~>` so patch releases
  are accepted automatically.
- Bump the cowboy comparison harness to cowboy 2.16.1 and cowlib 2.17.1,
  and `proper` to 1.5.0, in the test and bench profiles.

## [0.3.1] - 2026-06-14

Maintenance release: an `instrument` bump and a documentation pass.

### Changed

- Upgrade `instrument` 1.1.3 -> 1.1.4.

### Documentation

- Rewrote the guides, tutorials, and concept pages in a task-oriented
  style. Each page opens with what it is and when you need it, then the
  concrete steps.
- Added an Ecosystem page linking the sibling libraries `livery_grpc`,
  `livery_s3`, and `livery_stripe`, on the site and in the API reference.

## [0.3.0] - 2026-06-13

Adds deferred responses, per-SNI certificate selection on HTTP/3, and
per-listener TLS options, with wire-dependency bumps.

### Added

- `livery_resp:stream_deferred/1`. The resolver fun runs at emit time, in
  the worker, before any header is written, and chooses the response shape:
  `{stream|sse|ndjson, Status, Headers, Producer}` or `{full, Status,
  Headers, Body}`. This lets a streaming handler reply with a non-2xx JSON
  error if admission fails before the first byte, instead of `200 OK` + an
  in-band error frame. Headers added by wrapping middleware merge under the
  decision's headers (decision wins on conflict).
- Per-SNI certificate selection on HTTP/3. `livery_h3` forwards a
  `sni_callback` (carried inside `quic_opts`) so an H3 listener picks its
  certificate per connection from the ClientHello SNI, mirroring the
  `ssl_opts`/`sni_fun` path on H1/H2. See
  `docs/guides/serve-multiple-certs-sni.md`.
- Per-listener TLS `ssl_opts` are forwarded to the underlying listeners.

### Changed

- Bump `h1` 0.6.1 -> 0.6.2, `quic` 1.6.4 -> 1.6.5, `webtransport`
  0.3.3 -> 0.4.0, `hackney` 4.2.3 -> 4.3.0.

## [0.2.7] - 2026-06-10

Maintenance release: a Hex resolution fix, an HTTP/1.1 WebSocket header
fix, and a push-streaming mode for the HTTP client.

### Added

- `livery_client` push streaming. Pass `stream_to => Pid` (with `stream
  => true`) and the response is delivered to `Pid` as ordered messages
  (`{livery_response, Ref, {status, Status, Headers}}`, `{chunk, Binary}`,
  `done`, `{error, Reason}`), so one process can interleave body chunks
  with its own control messages in a selective receive instead of
  dedicating a process to a blocking read loop. `flow => manual` sends one
  chunk per `stream_next/1` for backpressure; `stop_stream/1` cancels and
  drops the connection. The `livery_client_adapter` behaviour gains
  optional `stream/3`, `stream_next/1`, and `stop_stream/1` callbacks. The
  pull-based `{stream, Reader}` + `read/2` API is unchanged.

### Fixed

- The package now resolves on Hex (#49). The published dependency pins
  conflicted: `barrel_mcp` 2.2.0 required `hackney` 4.0.3 / `h2` 0.6.1 /
  `erlang_h1` ~>0.2.3, and `hackney` 4.2.2 required `h2` 0.8.0, neither
  of which agrees with Livery's own pins. The dependency bumps below put
  the whole graph on `h2` 0.9.0. (Local builds use git deps, which skip
  Hex version resolution, so the conflict never showed up in CI.)
- HTTP/1.1 WebSocket upgrade: the `101 Switching Protocols` response no
  longer carries duplicate `Connection`/`Upgrade` headers, which
  spec-strict clients (Safari, undici) reject. Fixed upstream in
  `erlang_h1` 0.6.1, which now owns those framing headers and strips any
  caller-supplied copies.

### Changed

- Bump dependencies onto a mutually compatible set:
  - `barrel_mcp` 2.2.0 -> 2.2.2 (now requires `hackney` 4.2.3 / `h2`
    0.9.0 / `erlang_h1` ~>0.6.1)
  - `erlang_h1` 0.6.0 -> 0.6.1
  - `hackney` 4.2.2 -> 4.2.3 (now requires `h2` 0.9.0)
  - `webtransport` 0.3.2 -> 0.3.3

## [0.2.6] - 2026-06-09

Maintenance release: a `barrel_mcp` bump that threads the authenticated
principal into MCP tool handlers. No Livery API change.

### Changed

- Bump `barrel_mcp` 2.1.0 -> 2.2.0. Arity-2 MCP tool handlers
  (`Mod:Fun(Args, Ctx)`) now receive the authenticated principal in
  `Ctx` under `auth_info`, so owner-scoped tools can identify the
  caller. The handler passes it through unchanged; no Livery API change.

## [0.2.5] - 2026-06-07

Maintenance release: HTTP client fixes and a `Retry-After`-aware retry
layer. No API change beyond the new retry option.

### Added

- The retry layer honors a `Retry-After` (delta-seconds) header on a
  retryable response, sleeping that long instead of the computed backoff,
  capped by the new `retry_after_max` option (default 120000 ms). An
  HTTP-date `Retry-After` falls back to backoff.

### Fixed

- The hackney client adapter no longer crashes on a bodyless response
  (HEAD, 204, 304), where hackney returns a three-tuple with no body.

### Changed

- Bump `hackney` 4.2.1 -> 4.2.2.

## [0.2.4] - 2026-06-06

Maintenance release: an HTTP/2 write-path optimization, an HTTP/2
disconnect fix, and a runtime concurrency-cap setter. No API change
beyond the added setter.

### Changed

- Bump `h2` to 0.9.0, which coalesces a response's frames into a single
  socket write instead of one write per frame. On the loopback benchmark
  this roughly doubles large HTTP/2 response throughput (100 KiB over TLS:
  ~28k -> ~66k req/s) and lifts smaller bodies ~7-9%.

### Fixed

- HTTP/2: a client that disconnects mid-response is reported as a normal
  disconnect (`{error, closed}`, matching HTTP/1.1's `gen_tcp:send`)
  instead of crashing the request. The crash path error-logged the full
  stacktrace, which carries the response body as a send argument, so a
  disconnect during a large response pretty-printed the whole body per
  request - a throughput sink and a log-hygiene leak.

### Added

- `livery_req_sup:set_max_concurrent_requests/1` changes the in-flight
  request cap at runtime. The cap is resolved once at startup and cached
  in `persistent_term` rather than read from the application environment
  on every request.

### Benchmarks

- `bench/compare.sh` compares livery, cowboy, and bandit over HTTP/1.1
  (`wrk`) and HTTP/2 over TLS (`h2load`) across realistic workloads (tiny
  GET, 1/10/100 KiB sized responses served from a cached payload, JSON
  echo `POST`), with a per-protocol summary table and an optional
  concurrency sweep.

## [0.2.3] - 2026-06-05

Maintenance release: dependency bumps and benchmark tooling. No API change.

### Changed

- Bump wire dependencies: `h1` (erlang_h1) 0.5.0 -> 0.6.0 (cuts
  per-request allocations, single-scan header parsing, one-pass response
  header block, header-block size cap), `quic` 1.6.3 -> 1.6.4, `hackney`
  4.2.0 -> 4.2.1, `webtransport` 0.3.1 -> 0.3.2.

### Added

- HTTP/3 in the cross-server benchmark (`bench/compare.sh`), measured with
  livery's in-VM `quic_h3` driver (livery only; cowboy and bandit have no
  HTTP/3), alongside the HTTP/1.1 (`wrk`) and HTTP/2-over-TLS (`h2load`)
  comparisons.

## [0.2.2] - 2026-06-05

Maintenance release: an H1 throughput optimization and benchmark tooling.
No API change.

### Changed

- H1 full responses coalesce into a single `content-length` socket write
  (`livery_h1:send_full/5` via the new `h1:respond/5`) instead of chunked
  framing over two writes, lifting H1 throughput about 24% in the loopback
  benchmark. Requires erlang_h1 0.5.0 (bumped from 0.4.0).

### Added

- Cross-server benchmark (`bench/compare.sh`) comparing livery, cowboy,
  and bandit over HTTP/1.1 (`wrk`) and HTTP/2 over TLS (`h2load`).

## [0.2.1] - 2026-06-04

Maintenance release: tests, docs, and internal layout. No API or
behaviour change.

### Added

- End-to-end test suite (`livery_e2e_SUITE`): boots the example notes
  service over H1, H2, and H3 and runs the same CRUD + middleware + SSE +
  WebSocket journey against each protocol.

### Changed

- Source tree grouped into domain subdirectories (`src/client`,
  `src/middleware`, `src/auth`, `src/codec`); the core runtime stays flat
  in `src/`. Pure relocation, no module renamed.
- README rewritten around runnable snippets.
- The example service registers its `/ws` route for any method, so the
  WebSocket upgrade works over H2/H3 extended CONNECT as documented.

## [0.2.0] - 2026-06-04

Closes the structural gap with Axum + Tower + Hyper: router composition,
first-class shared state, and a composable HTTP client that mirrors the
middleware model outbound, including load balancing across endpoints.

### Added

- Router composition. `livery_router:nest/2,3` mounts a sub-router under a
  path prefix and `livery_router:merge/1,2` combines routers, so an area
  (for example an MCP mount) can be assembled on its own and grafted in.
- First-class service config. `livery:start_service/1` takes a `config`
  map shared by every handler and middleware, read with
  `livery_req:config/1,2,3` (the `with_state` analogue).
- Composable HTTP client (`livery_client`): the outbound twin of the
  middleware. Build a client with a transport adapter, base URL, default
  headers, and a layer stack, then call it. Ships timeout, retry,
  concurrency-limit, and circuit-breaker layers, streamed request and
  response bodies, and a `livery_client_adapter` behaviour (default
  `livery_client_hackney`, covering HTTP/1.1, HTTP/2, and HTTP/3).
- Client load balancing. A `livery_client:balance/1` layer spreads
  requests across a pool of endpoints with power-of-two-choices or
  round-robin selection, passive outlier ejection, and lazy half-open
  recovery. Pools are seeded from a static list or a
  `livery_client_discover` provider and can be changed at runtime with
  `add_endpoint/2` and `remove_endpoint/2`.
- Bind to a specific listen address, including IPv6 (`livery_inet`), and
  reduced per-request overhead.
- Cowboy cutover validation. `examples/livery_example_migration.erl`
  expresses the common Cowboy patterns (plain handler, REST resource,
  SSE, a `cowboy_loop`-style streaming endpoint, WebSocket echo) in
  Livery, and `test/livery_cowboy_parity_SUITE.erl` runs that handler set
  behind both a live Cowboy listener and Livery, diffing the observable
  behaviour over H1, then drives the same Livery handlers over H2 and H3.

### Changed

- Wire dependencies moved to hex and bumped: `quic` 1.6.3, `h2` 0.8.0,
  `webtransport` 0.3.1, `hackney` 4.2.0, `instrument` 1.1.3.

### Fixed

- H1 query string handling.
- Low-severity security hardening across the adapters.

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

[0.3.2]: https://github.com/benoitc/livery/releases/tag/v0.3.2
[0.3.1]: https://github.com/benoitc/livery/releases/tag/v0.3.1
[0.3.0]: https://github.com/benoitc/livery/releases/tag/v0.3.0
[0.2.7]: https://github.com/benoitc/livery/releases/tag/v0.2.7
[0.2.6]: https://github.com/benoitc/livery/releases/tag/v0.2.6
[0.2.5]: https://github.com/benoitc/livery/releases/tag/v0.2.5
[0.2.4]: https://github.com/benoitc/livery/releases/tag/v0.2.4
[0.2.3]: https://github.com/benoitc/livery/releases/tag/v0.2.3
[0.2.2]: https://github.com/benoitc/livery/releases/tag/v0.2.2
[0.2.1]: https://github.com/benoitc/livery/releases/tag/v0.2.1
[0.2.0]: https://github.com/benoitc/livery/releases/tag/v0.2.0
[0.1.0]: https://github.com/benoitc/livery/releases/tag/v0.1.0
