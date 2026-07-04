# Livery Design Document

## 1. What Livery is

Livery is a modern Erlang web framework. You define routes, handlers,
and a middleware stack once. Livery serves them over HTTP/1.1,
HTTP/2, and HTTP/3 on the same host, WebSocket on any of the three,
WebTransport on H2 and H3, Server-Sent Events on all three, and MCP
Streamable HTTP at `/mcp`, with OIDC/OAuth2, OpenAPI 3.1, and
OpenTelemetry-style observability as built-in middleware.

It is written in the spirit of Axum + Tower + Hyper. It does not
reimplement the wire: the three HTTP protocol libraries
(`h1`, `h2`, `quic`/`quic_h3`) and the WebSocket library (`ws`) are
separate hex packages that Livery consumes as deps. Livery is the
developer-facing layer on top of them.

## 2. Problem

Erlang has several HTTP servers. None of them delivers the full
modern web surface in one place:

- Cowboy covers H1, H2, and has WS and SSE, but no H3, no built-in
  OpenAPI, no OIDC, no MCP, and its middleware story is ad-hoc.
- There is no BEAM-native framework with first-class H3 and
  WebTransport.
- Libraries for MCP (Model Context Protocol) exist but are tied to
  Cowboy and force a second listener next to the main app.
- Observability requires wiring telemetry, a tracer, a metrics
  backend, and log correlation by hand.

The result is that building a small production service in Erlang
today involves gluing several libraries together and still missing
things that are table stakes in Rust/Go (H3, Alt-Svc upgrade,
OpenAPI, OIDC, MCP).

Livery closes that gap. One dep, one config, one router, one
middleware stack.

## 3. Who it is for

- Teams building REST or GraphQL APIs who want H3 and HTTP/2 out of
  the box and browser-friendly SSE without extra libraries.
- Teams building agent or tool servers that need MCP over HTTP, with
  authentication and tracing already wired.
- Teams that already run Erlang/OTP and want to stop importing
  Cowboy plus ten adjunct libraries.
- New Erlang adopters who have used Axum, Fastify, or FastAPI and
  expect the same ergonomics.

## 4. Design principles

1. **Protocol neutrality.** The handler does not know whether it is
   talking over H1, H2, or H3. The request value is the same. The
   response value is the same. Differences surface only through
   capabilities (`trailers`, `extended_connect`, `datagrams`).
2. **Race H3, fall back to H2, fall back to H1.** A service runs all
   three on the same host, one router and one middleware stack
   serving the lot, and advertises Alt-Svc so clients can upgrade.
3. **Thin adapters.** Each protocol adapter is a translator, not a
   state machine. Flow control, HPACK, QPACK, QUIC, framing all live
   upstream.
4. **Axum + Tower ergonomics.** Axum-style handler signature and
   extractors. Tower-style ordered middleware stack with request and
   response transformation.
5. **Data, not processes.** Requests and responses are values.
   Middleware transforms values. Processes only exist where they
   earn their keep: per-request process for isolation, listener
   processes for socket ownership.
6. **Backpressure by default.** Streaming bodies read on demand.
   When a client stalls, Livery applies backpressure to the handler
   before it falls behind the wire.
7. **Composable integrations.** Auth, MCP, OpenAPI, WebTransport,
   and instrumentation are modules in the same app, engaged only
   when the user mounts or configures them. They share the adapter
   stack and middleware pipeline.
8. **No secret sauce in the wire.** Anything visible on the network
   is the job of the wire libraries. If something is wrong at the
   frame or stream level, the fix lands there, not in Livery.

## 5. Architecture at a glance

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

Wire is three sibling libraries plus `ws`. Livery is one OTP app
consuming them. There is one `livery_sup`, one `livery_req_sup`,
and three listener subtrees (H3, H2, H1) created by
`livery_service` as needed.

## 6. Developer experience

### 6.1 Handler

```erlang
-module(hello).
-export([index/1, greet/1]).

index(Req) ->
    livery_resp:text(200, <<"hello, world">>).

greet(Req) ->
    Name = livery_req:binding(<<"name">>, Req, <<"stranger">>),
    livery_resp:text(200, [<<"hello, ">>, Name]).
```

### 6.2 Service with all three protocols

```erlang
Router =
    livery_router:compile([
        {<<"GET">>, <<"/">>,         {hello, index}},
        {<<"GET">>, <<"/hi/:name">>, {hello, greet}}
    ]),

Middleware =
    [ livery_middleware:wrap(fun livery_errors:to_resp/3)
    , {livery_instrument_trace,   #{}}
    , {livery_instrument_metrics, #{}}
    , {livery_auth_bearer,        #{issuer => <<"https://auth.example">>}}
    ],

livery:start_service(#{
    host       => <<"example.com">>,
    http3      => #{port => 443, cert => Cert, key => Key},
    https      => #{port => 443, cert => Cert, key => Key,
                    alpn  => [h2, http1]},
    http       => #{port => 80, redirect => https},
    router     => Router,
    middleware => Middleware,
    alt_svc    => advertise
}).
```

One call brings up H3 on UDP:443, H2 on TLS:443, and H1 on TCP:80.
Responses on H1 and H2 carry `Alt-Svc: h3=":443"`, so clients race
and upgrade to H3 on the next request.

### 6.3 Extractors

```erlang
create_user(Req) ->
    case livery_ext:json(Req) of
        {ok, #{<<"email">> := Email}} ->
            ok = users:create(Email),
            livery_resp:empty(201);
        {error, malformed_json} ->
            livery_resp:text(400, <<"bad json">>);
        {error, {missing, <<"email">>}} ->
            livery_resp:text(422, <<"email required">>)
    end.
```

### 6.4 WebSocket

```erlang
upgrade_chat(Req) ->
    livery_ws:upgrade(Req, chat_handler, #{}).
```

`chat_handler` implements `ws_handler` from `erlang_ws`. Livery
plugs a transport adapter that drives the same stream whether the
client arrived over H1 `Upgrade: websocket`, H2 extended CONNECT
(RFC 8441), or H3 extended CONNECT (RFC 9220).

### 6.5 SSE

```erlang
stream_events(Req) ->
    livery_resp:sse(200, fun(Emit) ->
        lists:foreach(
            fun(I) -> Emit(#{event => tick, data => integer_to_binary(I)}) end,
            lists:seq(1, 10))
    end).
```

### 6.6 Streaming NDJSON

```erlang
pull(Req) ->
    livery_resp:ndjson(200, fun(Emit) ->
        Ref = pipeline:subscribe(self()),
        emit_loop(Ref, Emit)
    end).

emit_loop(Ref, Emit) ->
    receive
        {Ref, {progress, Pct}} ->
            Emit(#{status => downloading, pct => Pct}),
            emit_loop(Ref, Emit);
        {Ref, done} ->
            Emit(#{status => done})
    end.
```

The callback runs in the per-request process and is free to
`receive` between emits. Livery hibernates the process during long
idle stretches (model pull, slow LLM token output). There is no
separate `loop` or `info/3` callback shape: a streaming handler is
a fun that yields chunks through `Emit`. The same model applies to
`livery_resp:sse/2` and `livery_resp:stream/3`. Client disconnect
surfaces as an error return from `Emit`. This is the Livery
replacement for Cowboy's `cowboy_loop`.

### 6.7 MCP

```erlang
Mcp = livery_mcp:handler(#{session_enabled => true}),
Router2 = livery_router:compile([
    {<<"POST">>,   <<"/mcp">>, Mcp},
    {<<"GET">>,    <<"/mcp">>, Mcp},
    {<<"DELETE">>, <<"/mcp">>, Mcp}
    | Routes
]),
livery:start_service(#{router => Router2, ...}).
```

`livery_mcp:handler/1` bridges to `barrel_mcp`'s protocol engine;
tools register through `barrel_mcp:reg_tool/4`. The MCP endpoint
reuses the same middleware stack, the same auth, the same tracing,
and is served over H1, H2, and H3 automatically.

## 7. Request lifecycle

1. Client arrives on one of the three listeners.
2. The protocol engine (`h1`, `h2`, `quic_h3`) decodes framing,
   header compression, and flow control. It invokes Livery's
   adapter handler fun with
   `(Conn, StreamId, Method, Path, Headers)`.
3. The adapter builds a `#livery_req{}`, spawns a `livery_req_proc`
   under `livery_req_sup` (simple_one_for_one), and redirects body
   messages to that pid. The engine continues to serve other
   streams.
4. The request process runs the middleware stack followed by the
   handler. The body reader drains adapter messages lazily with
   bounded buffering.
5. The handler returns `#livery_resp{}`. Core walks the body
   variant (`{full, _}`, `{chunked, Fun}`, `{sse, Fun}`,
   `{file, _, _}`, `{upgrade, _, _}`) and drives the adapter's
   `send_headers/send_data/send_trailers`.
6. On client disconnect, the adapter resets the stream; the
   request process observes it and terminates.

No part of this pipeline is protocol-specific above the adapter
boundary.

## 8. Core concepts

| Concept           | Module              | Shape                                                          |
|-------------------|---------------------|----------------------------------------------------------------|
| Request           | `livery_req`        | `#livery_req{}` value, pattern-matchable                       |
| Response          | `livery_resp`       | `#livery_resp{}` value built by pure builders                  |
| Router            | `livery_router`     | Radix-style path trie, static, `:param`, `*wildcard`           |
| Middleware        | `livery_middleware` | Ordered list, `call(Req, Next, State) -> Resp`                 |
| Extractors        | `livery_ext`        | `json/1`, `form/1`, `path_param/2`, `query/2`, `bearer_token/1`|
| Body              | `livery_body`       | Opaque reader, lazy, bounded buffer                            |
| Adapter behaviour | `livery_adapter`    | `start, stop, send_headers, send_data, send_trailers, reset`   |
| Service runtime   | `livery_service`    | Orchestrates H3+H2+H1, Alt-Svc, drain                          |

## 9. Protocol race and fallback

A live public service on :443 will typically receive requests in
four flavours over time:

1. New client on H3: direct to UDP:443. Fastest path.
2. New client on H2 or H1: hits TLS:443 or TCP:80. Response carries
   `Alt-Svc: h3=":443"` so the next request races.
3. Client on H1, no H3 support: stays on H1. Livery serves it.
4. Client upgrading within a session: H1 with `Upgrade: websocket`,
   H2 with RFC 8441 extended CONNECT, H3 with RFC 9220 extended
   CONNECT. All three land in the same handler via `livery_ws`.

The service contract is: one handler, any client, best available
transport.

## 10. Feature surface

- **REST:** router, extractors, JSON response builder (user-chosen
  codec), content negotiation helpers, ranges on file responses.
- **OpenAPI:** routes carry metadata, `livery_openapi:build/1`
  emits a 3.2 document, `/openapi.json` is served, optional
  request/response validation middleware, Redoc and Swagger UI
  from `priv/`.
- **MCP:** Streamable HTTP handler mounted at a user-chosen path,
  bridging to `barrel_mcp`'s protocol core. No second listener. No
  separate auth. No separate tracing.
- **WebSocket:** RFC 6455 via `ws` with upgrade paths for H1
  (Upgrade), H2 (RFC 8441), H3 (RFC 9220). Permessage-deflate
  available.
- **WebTransport:** via `webtransport` on H2 and H3. Datagram send
  and bidirectional streams.
- **SSE:** `livery_resp:sse/2` with heartbeat and disconnect
  detection, works identically on H1 (chunked), H2 (DATA frames),
  H3 (DATA frames).
- **Auth:** OIDC discovery, JWKS rotation, JWT RS256 and ES256
  verification, optional RFC 7662 introspection, optional session
  cookie. `livery_auth_bearer` middleware, `user/1` extractor in
  `livery_ext`.
- **Observability:** `livery_instrument_trace` opens a span per
  request via `instrument_tracer`, propagates W3C traceparent,
  attaches HTTP semantic attributes. `livery_instrument_metrics`
  records counters, gauges, and histograms via `instrument_meter`
  following the OpenTelemetry HTTP server semantic conventions.
  Structured logs carry `trace_id` and `span_id`.
- **Graceful shutdown:** `livery_drain` stops accepting new
  streams, lets in-flight requests finish within a configurable
  window, then closes.
- **Built-in middleware:** `livery_request_id` generates or honors
  `X-Request-ID`; `livery_body_limit` caps inbound body size with
  a 413 response; `livery_timeout` enforces a per-route deadline
  with a 504 response; `livery_access_log` emits one structured
  log line per request (the in-stack replacement for Cowboy's
  `cowboy_stream` access-log handler). Each is opt-in by adding it
  to the user's middleware stack.

## 11. Performance principles

- Zero-copy iodata through the pipeline. No per-chunk
  serialization round-trips.
- Header lists lowercased on ingest once; lookups are case-direct
  after that.
- Per-request process is short-lived and uses minimal heap. No
  gen_server mailbox churn for small requests.
- Streaming reads demand-driven, bounded buffer, reset on
  overflow.
- Dispatch path dialyzer-clean and inline-friendly.
- Continuous benchmarks against a reference handler on wrk, h2load,
  and quiche-client. CI fails on a p99 regression larger than 10
  percent.

## 12. Out of scope

- HTTP/2 server push (PUSH_PROMISE). Deprecated, disabled in
  browsers.
- HTTP/2 priority tree. Replaced by RFC 9218 and handled upstream
  in `h2` if at all.
- In-tree HTTP/1.1 parser, HPACK, QPACK, QUIC state machine. Owned
  by the wire libraries.
- Built-in HTML templating, view helpers, ORM. Composable with
  user-chosen libraries.
- Built-in JSON codec. Users plug `thoas`, `jsx`, or any other
  codec. Livery's `json/2` accepts pre-encoded iodata.

## 13. Success criteria

Livery v1.0 ships when:

1. `livery:start_service/1` brings up H1, H2, and H3 on :443/:80,
   all serving one handler set.
2. `test/livery_parity_SUITE.erl` is green: the same handler matrix
   passes against `livery_test_adapter`, `livery_h1`, `livery_h2`,
   `livery_h3`.
3. `h2spec`, QUIC interop (quiche-client, ngtcp2-client), and
   Autobahn suites are green in docker-CI.
4. A Keycloak-protected route, an `/openapi.json`, an MCP tool
   over Inspector, a WebSocket echo, an SSE feed, and a WT echo
   session all work from a single umbrella service.
5. Tracing is visible in Jaeger with the HTTP semantic attributes
   set and `traceparent` propagated.
6. Performance on the reference handler is within 10 percent p99
   of the legacy baseline.
7. `rebar3 dialyzer` and `rebar3 xref` are clean.
8. `erllama_server` runs against `livery:start_service/1` over the
   full H3 -> H2 -> H1 chain: its CT suite passes when driven over
   H1, H2, and H3 with the same handler set, NDJSON streaming on
   `/api/pull` and `/api/chat` works on each protocol, and clients
   race up to H3 via Alt-Svc. Concrete proof that Livery replaces
   Cowboy in a live service and unlocks H2 and H3 in the process.
