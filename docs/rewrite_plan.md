# Livery Rewrite Plan

Livery is being restarted as a BEAM-native, protocol-independent application
server for REST APIs, MCP tools, and streaming services over HTTP/1.1,
HTTP/2, HTTP/3, and WebTransport. The current codebase is preserved in
`legacy/` as a reference. Livery reuses external protocol libraries for wire
work and focuses on routing, middleware, handlers, and integrations.

Target architecture:

```
                 ┌─────────────────────┐
                 │       livery        │
                 │  service runtime    │
                 └──────────┬──────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   livery_h1           livery_h2           livery_h3
 erlang_h1 adapter   erlang_h2 adapter   erlang_quic/h3
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                     livery_core
                            │
                   middleware pipeline
                            │
                         router
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
      REST               MCP              streaming/SSE
   OpenAPI JSON     Streamable HTTP       browser events
```

## 1. Goals and non-goals

Goals:
- Protocol-agnostic service runtime on top of dedicated wire libraries.
- Axum-style handler and extractor ergonomics in Erlang.
- First-class OpenAPI, MCP Streamable HTTP, SSE, OpenTelemetry, OIDC/OAuth2.
- Preserve the current Livery in `legacy/` as a reference and selective port
  source.

Non-goals:
- No in-tree reimplementation of HPACK, QPACK, frame decoders, parsers, or
  QUIC state machines. Those live in the protocol libraries.
- No public API compatibility with current `livery_*` modules.
- No HTTP/2 server push, no HTTP/2 priority tree.

## 2. Repository restructuring

Move the entire current tree into `legacy/` preserving relative paths:

```
legacy/
  src/              current Livery modules
  include/
  test/
  examples/
  benchmark/
  docker/
  priv/
  docs/             old docs, excluded from ex_doc
  rebar.config.legacy
  README.legacy.md
```

`legacy/` is not a rebar app, is not compiled, and is not referenced by the
new build. Add a one-line `legacy/README.md` stating the git SHA it was
frozen from. CI has a guard rule: no source file under `apps/` may reference
a module under `legacy/`.

New top-level layout (umbrella):

```
apps/
  livery/              public facade, listener supervision, config
  livery_core/         req/resp, router, middleware, extractors, response builders
  livery_h1/           thin adapter over erlang_h1
  livery_h2/           thin adapter over erlang_h2
  livery_h3/           thin adapter over erlang_quic's quic_h3 subsystem
  livery_ws/           WebSocket over h1 and h2, ported from legacy
  livery_wt/           WebTransport adapter over erlang-webtransport
  livery_mcp/          mount barrel_mcp Streamable HTTP at /mcp
  livery_openapi/      OpenAPI generation and validation
  livery_otel/         OpenTelemetry instrumentation
  livery_auth/         OIDC / OAuth2 middleware and extractors
docs/                  new documentation
test/                  umbrella integration and parity suites
rebar.config           umbrella
```

Rationale: each protocol adapter can ship as a separate hex package, the
core stays tiny, MCP and OpenAPI are optional integrations.

## 3. Dependency inventory

Server-side protocol libraries (sibling checkouts during development, hex
once stabilized):

| Dep                   | Path                         | Role                                                 | Classification     |
|-----------------------|------------------------------|------------------------------------------------------|--------------------|
| erlang_h1             | ../erlang_h1                 | HTTP/1.1 wire, extended CONNECT, capsules            | Required (server)  |
| erlang_h2             | ../erlang_h2                 | HTTP/2 wire, HPACK, extended CONNECT, capsules       | Required (server)  |
| erlang_quic           | ../erlang_quic               | QUIC, quic_h3 subsystem, QPACK                       | Required (server)  |
| erlang-webtransport   | ../erlang-webtransport       | WebTransport sessions over h2 and h3                 | Optional (wt)      |
| barrel_mcp            | ../barrel_mcp                | MCP protocol, Streamable HTTP, auth adapters        | Optional (mcp)     |
| hackney               | ../hackney                   | Reference HTTP client for tests and interop          | Dev and test only  |
| telemetry             | hex                          | Telemetry event emission                             | Required           |
| opentelemetry         | hex                          | OTel SDK                                             | Optional (otel)    |
| thoas or jsx          | hex                          | JSON encoding and decoding                           | Required           |
| jesse or similar      | hex                          | JSON Schema validation for OpenAPI                   | Optional (openapi) |

Nothing in `legacy/` is a build dependency.

## 4. Target architecture

### 4.1 Layering

1. Transport: TCP, TLS, UDP+QUIC, owned by the protocol libraries.
2. Protocol engines: erlang_h1, erlang_h2, erlang_quic/h3. Each exposes a
   connection-handler callback that hands Livery a request-ish event stream.
3. Adapters (`livery_h1`, `livery_h2`, `livery_h3`): translate
   protocol-specific events into a uniform `livery_req` value and route
   response calls back to the engine. No wire decoding lives here.
4. Core (`livery_core`): router, middleware pipeline, handler dispatch,
   body streaming, header normalization, extractors, response builders.
5. Service (`livery`): listener config, app supervision, public start and
   stop API.
6. Integrations: `livery_ws`, `livery_wt`, `livery_mcp`, `livery_openapi`,
   `livery_otel`, `livery_auth`.

### 4.2 Common request and response abstraction

One shape for all three HTTP versions:

- `method`, `scheme`, `authority`, `path`, `query`
- `headers`: list of `{Name, Value}`, lowercased names
- `body`: `{received, iodata()}` or `{streaming, Reader}` or `empty`
- events flowing back: `{trailers, Headers}`, `{reset, Reason}`
- `protocol`: `h1 | h2 | h3`
- `peer`, `tls`, `alpn`
- opaque `stream` handle used by adapters for
  `send_headers`, `send_data`, `send_trailers`, `reset`.

Handlers return a response value. Adapters know how to emit it.
`livery_core` never touches sockets.

### 4.3 Axum-style handlers

Backport extractor ergonomics as explicit Erlang helpers rather than types:

```
-export([handle/2]).
handle(Req, _State) ->
    {ok, Body} = livery_ext:json(Req),
    livery_resp:json(200, compute(Body)).
```

Extractors (`livery_ext`): `json/1`, `form/1`, `path_param/2`, `query/2`,
`header/2`, `bearer_token/1`, `user/1`. Each returns a typed error that the
default middleware maps to an HTTP status.

Response builders (`livery_resp`): `text/2`, `json/2`, `stream/3`, `sse/2`,
`file/2`, `redirect/2`, `status/1`.

### 4.4 Middleware pipeline

Tower-style ordered list. Signature:

```
-callback call(Req, Next, State) -> Resp.
```

Built-ins: request id, structured logging, OTel span, auth, CORS,
compression, body size limit, request timeout, rate limit, OpenAPI
validation. Composable per-listener and per-route.

### 4.5 Router

Radix trie with typed path parameters. Routes are a data value, not code.
Supports method filters, per-route middleware stacks, and mount points
(`/mcp`, `/api/v1`, `/openapi.json`, `/metrics`).

## 5. Where each concern lives

| Concern               | App                        | Notes                                                                 |
|-----------------------|----------------------------|-----------------------------------------------------------------------|
| Wire framing          | erlang_h1 / h2 / quic      | Outside Livery                                                        |
| Listener config       | livery                     | `livery:start/2` dispatches to adapters by ALPN or explicit protocol  |
| Adapter               | livery_h1 / h2 / h3        | Convert engine callbacks into `livery_req` and back                   |
| Router                | livery_core                | Shared across all adapters                                            |
| Middleware            | livery_core                | Shared across all adapters                                            |
| REST + OpenAPI        | livery_openapi             | Route annotations emit `/openapi.json`, optional validation           |
| MCP                   | livery_mcp                 | Mounts `barrel_mcp_http_stream` at `/mcp`, bridges auth to livery_auth|
| SSE                   | livery_core + livery_resp  | Chunked on h1, DATA frames on h2 and h3                               |
| WebSocket             | livery_ws                  | Ported from legacy, rewired to new adapter API                        |
| WebTransport          | livery_wt                  | Thin glue to erlang-webtransport sessions on h2 and h3                |
| OpenTelemetry         | livery_otel                | Tracing middleware, metrics via telemetry bridge                      |
| Auth (OIDC, OAuth2)   | livery_auth                | JWT validation, JWKS rotation, introspection, middleware + extractor  |

## 6. Phased implementation order

Phase 0, preservation, half a day.
 Move the current tree into `legacy/`, add umbrella skeleton that boots with
 no routes. CI green on empty apps.

Phase 1, core skeleton, one week.
 `livery_req`, `livery_resp`, adapter behaviour, router, middleware
 pipeline, extractors, response builders. In-memory test adapter, property
 tests for router and middleware ordering.

Phase 2, H1 adapter, one week.
 `livery_h1` over erlang_h1. Echo, routed handlers, streaming bodies,
 trailers, keep-alive, 100-continue passthrough. Port compliance subset.

Phase 3, H2 adapter, one week.
 `livery_h2` over erlang_h2. Extended CONNECT, trailers, flow control
 delegated to erlang_h2.

Phase 4, H3 adapter, one week.
 `livery_h3` over erlang_quic/h3. Extended CONNECT, trailers, ALPN
 negotiation.

Phase 5, WebSocket, three to five days.
 Port `legacy/src/livery_ws.erl` onto the new adapter API, keep the
 masking, framing state machine, and control frame rules.

Phase 6, SSE and streaming, two to three days.
 `livery_resp:sse/*`, backpressure, heartbeat, client-disconnect detection.

Phase 7, observability, three to five days.
 `livery_otel`, telemetry events, structured logging middleware.

Phase 8, auth, one week.
 `livery_auth`: OIDC discovery, JWKS rotation, JWT verification, token
 introspection, optional session cookie.

Phase 9, OpenAPI, one week.
 Route metadata, spec generation, `/openapi.json`, opt-in validation
 middleware, Redoc and Swagger UI serving.

Phase 10, MCP, one week.
 Mount `barrel_mcp_http_stream` at `/mcp` via `livery_mcp`. Map
 `livery_auth` identities to `barrel_mcp_auth_*` backends.

Phase 11, WebTransport, optional, one week.
 `livery_wt` glue over erlang-webtransport for CONNECT sessions on h2 and
 h3.

Phase 12, docs and examples, ongoing.
 Getting started, handlers, extractors, MCP, OpenAPI, observability,
 migration from legacy.

Phase 13, benchmarks and soak, one week.
 Rewrite `docker/benchmarks` against the new stack, compare with legacy
 baseline on the same hardware.

## 7. Legacy disposition

Port, rewrite on top of the new adapter API, keep the logic:

- `livery_ws.erl` to `livery_ws`. Masking, frame state machine, control
  frame rules remain valuable.
- `livery_router.erl` to `livery_core` router. Radix trie is worth keeping.
- `livery_middleware.erl` to `livery_core` middleware composition.
- `livery_hooks.erl` only if design review keeps it separate from
  middleware, otherwise collapse.
- `livery_shutdown.erl` to `livery` drain logic, adapted to per-adapter
  quiesce.
- `livery_info.erl` to `livery` introspection.

Reference only, consult during implementation, do not port:

- `livery_h1.erl`, `livery_h1_parse*.erl`, replaced by erlang_h1.
- `livery_h2.erl`, `livery_h2_frame.erl`, `livery_hpack.erl`, replaced by
  erlang_h2.
- `livery_h3.erl`, `livery_h3_frame.erl`, `livery_qpack.erl`, replaced by
  erlang_quic.
- `livery_acceptor*.erl`, `livery_connection.erl`. Socket lifecycle now
  owned by the protocol libraries.
- `test/compliance/*`. Selectively port against the new stack.

Discard:

- `livery_huffman_lookup.hrl`. Lives in erlang_h2 and erlang_quic.
- `rebar3.crashdump`, `erl_crash.dump`.
- Benchmark scripts that hard-depend on legacy internals.

## 8. Test and validation strategy

Unit.
 Router, middleware, extractors, response builders, SSE framing, auth
 validators, OpenAPI spec generation, MCP mounting. EUnit plus PropEr.

Adapter.
 One suite per adapter (h1, h2, h3, ws, wt) driving a loopback listener
 with a matching client. hackney for h1 and h2, erlang_h2 client for h2,
 quic client for h3. Assert req/resp round-trip parity across protocols.

Cross-protocol parity.
 Same handler set exercised against all three adapters. Diff the externally
 observable behaviour: status, normalized headers, body, trailers,
 streaming cadence. A parity regression fails the build.

Compliance.
 Framing compliance stays in the protocol libraries, which own h2spec,
 QPACK interop, QUIC interop. Livery keeps HTTP semantics tests: method
 handling, status code mapping, conditional requests, content negotiation,
 range requests.

Interop.
 h2spec and h3spec against Livery listeners in CI via docker. MCP Inspector
 against `/mcp`. OWASP ZAP baseline or Lighthouse against sample routes.

Performance.
 wrk, bombardier, h2load, quiche-client in `docker/benchmarks`. Track p50
 and p99 versus the legacy baseline. Fail CI on a regression above ten
 percent for the reference handler.

Observability.
 Jaeger in CI, assert span tree shape for a known request matrix.

## 9. Risks and mitigations

| Risk                                                                           | Likelihood | Impact | Mitigation                                                                                     |
|--------------------------------------------------------------------------------|------------|--------|------------------------------------------------------------------------------------------------|
| erlang_h1, h2, quic APIs shift during the rewrite                              | High       | High   | Pin sibling path deps. Keep adapters thin so breakage is localized. Negotiate API changes upstream first. |
| Cross-protocol semantic drift (trailers, CONNECT, body framing)                | High       | Medium | Parity test suite from Phase 2. Adapters converge on `livery_req`, not the other way round.    |
| WebSocket over HTTP/2 needs RFC 8441 support in erlang_h2                      | Medium     | Medium | Gate WS on h2 behind extended CONNECT capability. Fall back to h1 cleanly.                     |
| WebTransport immaturity in the ecosystem                                       | Medium     | Low    | Keep as optional profile. Do not block core milestones.                                        |
| barrel_mcp session model leaks into core                                       | Medium     | Medium | Confine to livery_mcp. Core only knows about the mount point.                                  |
| OpenAPI annotation design churn                                                | High       | Low    | Generate from route metadata only at first. Validation middleware is opt-in. Iterate in minor releases. |
| Performance regression versus current Livery                                   | Medium     | High   | Continuous benchmark harness from Phase 2. Legacy numbers stay as baseline.                    |
| Test coverage gap during transition                                            | Medium     | High   | Port compliance and e2e suites early, per adapter.                                             |
| Long-lived `legacy/` tempts hybrid builds                                      | Low        | Medium | `legacy/` is not compiled. CI forbids `apps/*` referencing `legacy/*`.                         |

## 10. Milestone execution plan

M0, week 1. Move to `legacy/`, umbrella skeleton, CI green on empty apps.
 Exit: `rebar3 compile` passes, `legacy/` frozen at a tagged SHA.

M1, weeks 2 to 3. Core plus H1 adapter, echo example, first parity tests.
 Exit: GET and POST with body, trailers, keep-alive via erlang_h1.

M2, weeks 4 to 5. H2 adapter, extended CONNECT, parity suite green across
 h1 and h2. Exit: h2spec clean.

M3, weeks 6 to 7. H3 adapter, parity across h1, h2, h3. Exit: h3 interop
 matrix green against at least two third-party clients.

M4, week 8. WebSocket, SSE, streaming. Exit: WS echo on h1 and, if
 available, on h2 via RFC 8441. SSE with heartbeat and disconnect
 detection.

M5, weeks 9 to 10. `livery_auth` and `livery_otel`. Exit: OIDC-protected
 route, end-to-end traces visible in Jaeger.

M6, weeks 11 to 12. `livery_openapi`. Exit: `/openapi.json` for a sample
 service, request validation opt-in, Redoc served.

M7, weeks 13 to 14. `livery_mcp`. Exit: MCP Inspector drives a sample tool
 at `/mcp` with OIDC bearer auth through `livery_auth`.

M8, week 15, optional. `livery_wt`. Exit: WebTransport echo session on h2
 and h3.

M9, week 16. Docs, examples, benchmarks, release candidate. Exit: RC tag,
 docs site published, benchmarks within ten percent of the legacy
 reference.

Hard gates between milestones: all prior parity and compliance suites still
green, dialyzer clean, xref clean, no p99 regression above ten percent on
the reference handler.
