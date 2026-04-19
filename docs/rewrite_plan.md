# Livery Rewrite Plan

Livery is a BEAM-native, protocol-independent application server for
REST APIs, MCP tools, and streaming services over HTTP/1.1, HTTP/2,
HTTP/3, and WebTransport. The wire layer is delegated to external
sibling libraries. Livery focuses on the developer surface: routing,
middleware, handlers, and integrations.

```
                 ┌─────────────────────┐
                 │       livery        │
                 │  service runtime    │
                 └──────────┬──────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   livery_h1           livery_h2           livery_h3
     over h1             over h2         over quic_h3
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

## 1. Goals and non-goals

Goals:
- Axum + Tower + Hyper ergonomics on the BEAM. Axum-style handlers
  and extractors, Tower-style middleware stack.
- One service runtime that races HTTP/3 (UDP) alongside HTTP/2 and
  HTTP/1.1 (TCP/TLS) on the same public host, with shared router,
  middleware, and Alt-Svc advertisement.
- First-class OpenAPI, MCP Streamable HTTP, SSE, OpenTelemetry-style
  tracing and metrics, OIDC/OAuth2.
- Reference `legacy/` when it helps, ignore it otherwise.

Non-goals:
- No in-tree reimplementation of HPACK, QPACK, frame decoders,
  parsers, or QUIC state machines. Those live in the wire libraries.
- No public API compatibility with the current `livery_*` modules.
- No HTTP/2 server push. No HTTP/2 priority tree.

## 2. Repository layout

Single OTP app, flat `src/`. Collapsing the earlier umbrella plan:
the wire separation is already done at the dep layer (`h1`, `h2`,
`quic`, `ws` are independent hex packages), so splitting Livery
itself into per-adapter apps added ceremony without payoff.

```
livery/
  src/
    livery.erl               public API
    livery_app.erl           OTP application
    livery_sup.erl           one supervisor
    livery_service.erl       H3 + H2 + H1 runtime, Alt-Svc, drain
    livery_req.erl           uniform request value
    livery_resp.erl          text, json, stream, sse, file, upgrade
    livery_router.erl        radix trie
    livery_middleware.erl    tower-style stack
    livery_ext.erl           extractors
    livery_body.erl          streaming body, backpressure
    livery_adapter.erl       internal behaviour
    livery_h1.erl            adapter over h1
    livery_h2.erl            adapter over h2
    livery_h3.erl            adapter over quic_h3
    livery_ws.erl            WebSocket upgrade over h1/h2/h3 via ws
    livery_sse.erl           SSE helpers
    livery_drain.erl         graceful shutdown
    livery_info.erl          introspection
    livery_req_proc.erl      per-request process
    livery_req_sup.erl       simple_one_for_one parent
    livery_auth.erl          OIDC, JWKS, JWT verify
    livery_auth_bearer.erl   bearer middleware
    livery_auth_session.erl  session cookie middleware
    livery_mcp.erl           MCP Streamable HTTP handler at /mcp
    livery_mcp_session.erl   session bridge onto barrel_mcp
    livery_instrument_trace.erl    tracing middleware
    livery_instrument_metrics.erl  counters via instrument_meter
    livery_openapi.erl       OpenAPI 3.1 spec generation
    livery_openapi_validate.erl  request/response validation middleware
    livery_wt.erl            WebTransport integration (optional)
  include/livery.hrl
  test/
  docs/rewrite_plan.md
  _checkouts/                local dep overrides (gitignored)
  legacy/                    frozen reference, not compiled
  rebar.config
```

## 3. Dependencies

Git deps declared in `rebar.config`, hex later:

| Dep            | Role                                              | When      |
|----------------|---------------------------------------------------|-----------|
| `h1`           | HTTP/1.1 wire                                     | required  |
| `h2`           | HTTP/2 wire, HPACK, extended CONNECT              | required  |
| `quic`         | QUIC, quic_h3 subsystem, QPACK                    | required  |
| `ws`           | WebSocket (RFC 6455 + RFC 8441 + RFC 9220)        | required  |
| `webtransport` | WT sessions over h2 and h3                        | Phase 11  |
| `barrel_mcp`   | MCP protocol core (library use, not Cowboy)       | Phase 10  |
| `instrument`   | Tracer, meter, propagation, logger bridge         | Phase 7   |
| `hackney`      | Reference client for tests only                   | test only |

Local development uses `_checkouts/` symlinks to the sibling projects
(`../erlang_h1`, `../erlang_h2`, `../erlang_quic`, `../erlang_ws`,
etc.). The repo `rebar.config` stays pointing at GitHub.

## 4. Core design

### 4.1 Service runtime

`livery:start_service/1` brings H3, H2, and H1 up together under one
supervisor, sharing the router and the middleware stack, and injects
`Alt-Svc: h3=":443"` on H1 and H2 responses so clients can upgrade:

```
livery:start_service(#{
    host => <<"example.com">>,
    http3 => #{port => 443, cert => Cert, key => Key},
    https => #{port => 443, cert => Cert, key => Key,
               alpn  => [h2, http1]},
    http  => #{port => 80, redirect => https},
    router => Router,
    middleware => Stack,
    alt_svc => advertise
}).
```

### 4.2 `livery_req` / `livery_resp`

One request value the three adapters fill from engine events:
`protocol`, `method`, `scheme`, `authority`, `path`, `raw_query`,
`bindings`, `headers`, `peer`, `tls`, `body`, `adapter`, `stream`,
`engine_pid`, `req_id`, `started_at`, `meta`.

`body` is one of `empty`, `{buffered, iodata()}`, `{stream, Reader}`.

Handlers return a `#livery_resp{status, headers, body, trailers}`
value. `body` is one of `{full, iodata()}`, `{chunked, Fun}`,
`{sse, Fun}`, `{file, Path, Range}`, `{upgrade, ws|wt, State}`.

Builders in `livery_resp`: `text/2`, `json/2`, `stream/3`, `sse/2`,
`file/2`, `redirect/2`, `status/1`. Extractors in `livery_ext`:
`json/1`, `form/1`, `path_param/2`, `query/2`, `header/2`,
`bearer_token/1`, `user/1`.

### 4.3 Adapter behaviour

Each of `livery_h1`, `livery_h2`, `livery_h3` implements:

```
start(Name, ListenSpec, Opts)   -> {ok, Listener}
stop(Listener)                  -> ok
send_headers(Stream, Status, Headers, #{end_stream})
send_data(Stream, IoData, #{end_stream, flush})
send_trailers(Stream, Trailers)
reset(Stream, Reason)
peer_info(Stream)
capabilities(Listener)          -> #{trailers, extended_connect,
                                     datagrams, capsules}
```

### 4.4 Dispatch

1. Engine calls the adapter's handler fun.
2. Adapter spawns a `livery_req_proc` under `livery_req_sup`
   (simple_one_for_one) and returns immediately.
3. Body/trailer/eof messages are routed to that pid.
4. Middleware and handler run in that process. Body reader drains
   messages with bounded buffering and backpressure.
5. Handler returns `#livery_resp{}`. Core walks the body variant and
   drives `adapter:send_*`.
6. Engine DOWN cancels the request. Request DOWN triggers
   `adapter:reset`.

## 5. Observability

`instrument` library (https://github.com/benoitc/instrument). Two
middlewares:

- `livery_instrument_trace`: per-request span via `instrument_tracer`,
  W3C `traceparent`/`tracestate` propagation, HTTP semantic
  attributes.
- `livery_instrument_metrics`: counters, gauges, histograms via
  `instrument_meter` only. Names and attributes follow the
  OpenTelemetry HTTP server semantic conventions.

Logs carry `trace_id` and `span_id` via `instrument_logger`.

## 6. Phase plan

- Phase 0, done: tree in `legacy/`, flat scaffold, `rebar3 compile`
  and `xref` green.
- Phase 1, 1 week: core (`livery_req`, `livery_resp`, `livery_body`,
  `livery_ext`, `livery_adapter`, `livery_router`,
  `livery_middleware`, `livery_req_proc`, `livery_req_sup`,
  `livery_test_adapter`, `livery_service` stub). In-memory test
  adapter exercises GET, POST with streaming body, trailers, SSE,
  reset.
- Phase 2, 1 week: `livery_h1` + parity suite green {test, h1}.
- Phase 3, 1 week: `livery_h2`, h2spec in docker-CI, parity
  {test, h1, h2}.
- Phase 4, 1 week: `livery_h3`, ALPN, `livery_service`, Alt-Svc,
  quiche-client and ngtcp2-client interop, parity {test, h1, h2, h3}.
- Phase 5, 1 to 2 weeks: `livery_ws`, Autobahn green.
- Phase 6, 3 days: SSE and streaming utilities.
- Phase 7, 1 week: observability (`livery_instrument_*`).
- Phase 8, 1 week: auth (`livery_auth*`).
- Phase 9, 1 week: OpenAPI (`livery_openapi*`).
- Phase 10, 1 week: MCP (`livery_mcp*`).
- Phase 11, 1 week, optional: WebTransport (`livery_wt`).
- Phase 12, 1 week: docs, examples, benchmarks, RC tag.

Each phase ends with parity, dialyzer, and xref green. Performance
must stay within 10% p99 of the legacy baseline on the reference
handler.

## 7. Verification

- EUnit plus PropEr for router, middleware, extractors, body.
- One CT suite per adapter.
- `test/livery_parity_SUITE.erl` runs a shared handler set across
  `livery_test_adapter`, `livery_h1`, `livery_h2`, `livery_h3` and
  diffs externally observable behaviour.
- Interop in docker-CI: h2spec, quiche-client, ngtcp2-client,
  Autobahn, MCP Inspector, Keycloak.
- End-to-end smoke at Phase 4 gate: one `livery:start_service/1`
  serves the same handler over H1, H2, H3 with Alt-Svc.

## 8. Legacy

`legacy/` is a frozen reference. Not compiled, not linked. Grep it
when useful (radix-trie shape, WebSocket close-code table, shutdown
drain sequence). No CI guard.

## 9. Risks

- Upstream API churn in `h1`/`h2`/`quic`/`ws`: keep adapters thin,
  push changes upstream rather than forking.
- Cross-protocol semantic drift: parity suite from Phase 2 forward.
- RFC 8441 or RFC 9220 gaps: gated via `capabilities/1`, WS on that
  protocol skipped until the upstream lands.
- `barrel_mcp` currently ships a Cowboy listener: we use its protocol
  core as a library only, replacing the transport.
- Performance regression vs legacy: benchmarks track p50/p99 from
  Phase 2 forward; CI fails on >10% p99 regression.
