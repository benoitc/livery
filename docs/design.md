# Livery Design Document

This is the long-form design of Livery: the problem it solves, the
rules it is built on, how a request flows, and what it leaves out. Read
it when you want the whole picture in one place. The reasons behind
specific choices are in
[Design decisions](concepts/architecture.md#design-decisions); the exact
API is in the module docs.

## 1. What Livery is

Livery is a modern Erlang web framework. You define routes, handlers,
and a middleware stack once. Livery serves them over HTTP/1.1,
HTTP/2, and HTTP/3 on the same host, WebSocket on any of the three,
WebTransport on H2 and H3, Server-Sent Events on all three, and MCP
and A2A agents on the main listener, with authentication (OpenID
Connect sign-in, bearer tokens, introspection, DPoP, passkeys),
OpenAPI 3.2, and OpenTelemetry-style observability as built-in
modules. `livery_client` gives you the same middleware model for the
calls your service makes.

It follows the ideas of Rust's Axum, Tower and Hyper. Livery does not
implement the protocols itself: the three HTTP libraries (`h1`, `h2`,
`quic`/`quic_h3`), the WebSocket library (`ws`) and `webtransport` are
separate hex packages, and Livery depends on them. Livery is the part
you write code against.

## 2. Problem

Erlang has several HTTP servers, but none of them gives you
everything a web service needs today in one place:

- Cowboy serves H1 and H2, with WebSocket and SSE, but has no H3, no
  OpenAPI, no OpenID Connect and no MCP, and its middlewares and stream
  handlers are two separate models.
- No Erlang framework serves H3 and WebTransport out of the box.
- The MCP (Model Context Protocol) libraries that exist are tied to
  Cowboy and need a second listener next to your application.
- Tracing, metrics and log correlation have to be wired by hand.

So a small production service in Erlang means gluing several libraries
together, and still going without things Rust and Go services take for
granted (H3, upgrading through Alt-Svc, OpenAPI, OpenID Connect, MCP).

Livery puts them in one dependency: one configuration, one router, one
middleware stack.

## 3. Who it is for

- Teams building REST or GraphQL APIs who want H3 and HTTP/2 without
  extra work, and SSE that browsers can use without extra libraries.
- Teams building agent or tool servers that need MCP over HTTP, with
  authentication and tracing already in place.
- Teams already on Erlang/OTP who want to stop adding Cowboy plus a
  handful of other libraries to every project.
- People new to Erlang who have used Axum, Fastify or FastAPI and
  expect to work the same way.

## 4. Design principles

Livery was announced with five rules. Every change is checked against
them (the `livery-foundations` skill in `.agents/skills/` does it for
you):

1. **Values, not handles.** `Req` and `Resp` are plain records, never a
   shared mutable handle, so they are easy to pass between processes and
   to test.
2. **Middleware is a continuation.** `call(Req, Next, State) -> Resp`.
   `Next` is the rest of the pipeline as a function, so wrapping it in a
   try/catch, a timeout or a span is just calling it inside your own
   code.
3. **Protocol neutrality.** A handler never knows whether it is on H1,
   H2 or H3. The request and response values are the same everywhere;
   differences show up only through capabilities and optional adapter
   callbacks.
4. **Thin adapters.** Framing, header compression, flow control, QUIC
   and TLS live in the wire libraries. An adapter translates between a
   library and Livery's values, nothing more, and a wire problem is
   fixed in its library.
5. **The same model outbound.** `livery_client` is the middleware model
   turned around: layers around an adapter.

What follows from them:

- **H3 first, then H2, then H1.** A service runs all three on the
  same host, with one router and one middleware stack for all of them,
  and advertises H3 with Alt-Svc so clients can move up to it.
- **Backpressure by default.** A handler reads its body at its own
  pace: each chunk it reads gives flow-control credit back to the wire
  library, so a slow handler holds the client back instead of buffering
  the body. On the way out, a full window makes `Emit` wait or return
  an error.
- **Features you add when you need them.** Auth, MCP, A2A, OpenAPI,
  WebTransport and instrumentation are modules in the same application,
  and do nothing until you mount or configure them. They all use the
  same adapters and the same middleware pipeline.

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

The protocols live in the wire libraries; Livery is one OTP
application on top of them. `livery_sup` holds what the whole node
shares (the `livery_req_sup` admission counter and the ETS stores). The
listeners run under their wire library's supervisor, and
`livery_service` starts and stops them.

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
    [ livery_middleware:wrap(fun(_Class, _Reason, _Stack) ->
          livery_resp:text(500, <<"internal error">>)
      end)
    , {livery_instrument_trace,   #{}}
    , {livery_instrument_metrics, #{}}
    , {livery_auth_bearer,        #{jwks_uri => <<"https://auth.example/jwks">>,
                                    issuer   => <<"https://auth.example">>}}
    ],

livery:start_service(#{
    host       => <<"example.com">>,
    http3      => #{port => 443, cert => Cert, key => Key},
    https      => #{port => 443, cert => Cert, key => Key,
                    alpn  => [h2, http1]},
    http       => #{port => 80},
    router     => Router,
    middleware => Middleware,
    alt_svc    => advertise
}).
```

One call brings up H3 on UDP:443, H2 and H1 together on TLS:443
(ALPN picks one per connection), and H1 on TCP:80. Responses on H1
and H2 carry `Alt-Svc: h3="example.com:443"`, so clients can switch to
H3 on their next request. Without `host`, the header gives only the
port: `h3=":443"`.

### 6.3 Extractors

```erlang
create_user(Req) ->
    case livery_ext:json(Req) of
        {ok, #{<<"email">> := Email}} ->
            ok = users:create(Email),
            livery_resp:empty(201);
        {ok, _} ->
            livery_resp:text(422, <<"email required">>);
        {error, invalid_json} ->
            livery_resp:text(400, <<"bad json">>)
    end.
```

`livery_ext:json/1` reads the body to the end (up to 1 MiB) and decodes
it.

### 6.4 WebSocket

```erlang
upgrade_chat(Req) ->
    livery_ws:upgrade(Req, chat_handler, #{}).
```

`chat_handler` implements `ws_handler` from `erlang_ws`. The same
handler runs whether the client came in over H1 with
`Upgrade: websocket`, over H2 with extended CONNECT (RFC 8441), or over
H3 with extended CONNECT (RFC 9220).

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

The fun runs in the request's own process, so it can `receive`
between two calls to `Emit`. When it waits a long time (a model
download, a slow language model), it can call `erlang:hibernate/0`
(OTP 28 and later) and use almost no memory meanwhile. Do not use
`erlang:hibernate/3`: it throws away the call stack, so the fun never
returns and the stream is never finished. There is no separate `loop` or `info/3`
callback: a streaming handler is a fun that sends chunks through
`Emit`, and `livery_resp:sse/2` and `livery_resp:stream/3` work the
same way. When the client goes away, `Emit` returns an error. This is
what replaces Cowboy's `cowboy_loop` in Livery.

### 6.7 MCP

```erlang
Router2 = livery_router:merge(Router, livery_mcp:router(#{session_enabled => true})),
livery:start_service(#{router => Router2, ...}).
```

`livery_mcp:handler/1` passes requests to `barrel_mcp`, which handles
the protocol; you register tools with `barrel_mcp:reg_tool/4`. The MCP
endpoint goes through the same middleware stack, auth and tracing as
the rest of your routes, and is served over H1, H2 and H3.

## 7. Request lifecycle

1. A client connects to one of the three listeners.
2. The wire library (`h1`, `h2` or `quic_h3`) handles framing, header
   compression and flow control, then calls the adapter's handler fun
   with `(Conn, StreamId, Method, Path, Headers)`.
3. The adapter builds a `#livery_req{}` and hands it to
   `livery_translator`. The translator asks `livery_req_sup` to admit
   the request, starts a `livery_req_proc` worker, and passes the body
   on to it as `{livery_body, Ref, _}` messages. The wire library keeps
   serving the other streams.
4. The worker runs the middleware stack, then the handler. The handler
   reads the body when it wants to; each chunk it reads lets the client
   send one more, so the client is never more than one flow window
   ahead.
5. The handler returns a `#livery_resp{}`. Livery looks at the body
   (`{full, _}`, `{chunked, Fun}`, `{sse, Fun}`, `{file, _, _}`,
   `empty`) and sends it with the adapter's `send_headers`,
   `send_data` and `send_trailers`. A WebSocket, WebTransport, MCP or
   A2A handler writes to the stream itself and returns `taken_over`, so
   Livery has nothing left to send.
6. If the client goes away, the translator sends the worker
   `{livery_disconnect, Ref, Reason}` and runs the callbacks registered
   with `livery_req:on_disconnect/2`. Sending to that client returns
   `{error, closed}`. The handler decides when to stop.

Above the adapter, none of these steps depends on the protocol.

## 8. Core concepts

| Concept           | Module              | Shape                                                          |
|-------------------|---------------------|----------------------------------------------------------------|
| Request           | `livery_req`        | `#livery_req{}` record you can pattern-match                   |
| Response          | `livery_resp`       | `#livery_resp{}` record built by plain functions               |
| Router            | `livery_router`     | Path tree with static segments, `:param` and `*wildcard`       |
| Middleware        | `livery_middleware` | Ordered list, `call(Req, Next, State) -> Resp`                 |
| Extractors        | `livery_ext`        | `json/1`, `form/1`, `path_param/2`, `query/2`, `bearer_token/1`|
| Body              | `livery_body`       | Reader that pulls the body as you read it, up to a limit       |
| Adapter behaviour | `livery_adapter`    | `start, stop, send_*, reset`, plus optional upgrade callbacks  |
| Translator        | `livery_translator` | Passes the body on, enforces `max_body`, flow control, disconnects |
| Service runtime   | `livery_service`    | Runs H3, H2 and H1 together, Alt-Svc, drain                    |
| Client            | `livery_client`     | Layers around an outbound adapter (hackney)                    |

## 9. Protocol race and fallback

A public service on port 443 sees four kinds of client over time:

1. A client that speaks H3 goes straight to UDP:443, the fastest way
   in.
2. A new client on H2 or H1 reaches TLS:443 or TCP:80. The response
   carries `Alt-Svc: h3=":443"`, so its next request can try H3.
3. A client on H1 without H3 support stays on H1, and Livery serves it.
4. A client opening a WebSocket uses `Upgrade: websocket` on H1,
   extended CONNECT on H2 (RFC 8441) or on H3 (RFC 9220). All three
   reach the same handler through `livery_ws`.

In short: one handler, any client, the best protocol that client
supports.

## 10. Feature surface

- **REST:** router, extractors, JSON responses (with the JSON library
  of your choice), content negotiation helpers, ranges on file
  responses.
- **OpenAPI:** routes carry their description, `livery_openapi:build/1`
  turns them into a 3.2 document served at `/openapi.json`, an optional
  middleware validates requests against it, and Redoc or Swagger UI
  pages load their assets from a CDN.
- **MCP:** a Streamable HTTP endpoint at the path you choose, backed by
  `barrel_mcp`. No second listener, and the same auth and tracing as
  your other routes.
- **WebSocket:** RFC 6455 through `ws`, over H1 (`Upgrade`), H2
  (RFC 8441) and H3 (RFC 9220), with permessage-deflate.
- **WebTransport:** through `webtransport` on H2 and H3, with datagrams
  and bidirectional streams.
- **SSE:** `livery_resp:sse/2,3` tells you when the client goes away,
  and behaves the same on H1 (chunked) and on H2 and H3 (DATA frames).
- **A2A:** `livery_a2a` serves an Agent-to-Agent agent (its card, the
  JSON-RPC and REST bindings, SSE streams), backed by `barrel_a2a`.
- **Client:** `livery_client` with timeout, retry, concurrency limit,
  circuit breaker and load-balancing layers, OAuth and DPoP, a cookie
  jar, and streamed bodies.
- **Auth:** bearer JWT verification (RSA, ECDSA, EdDSA) with JWKS
  rotation, RFC 7662 introspection, DPoP and certificate-bound tokens,
  signed session cookies, OpenID Connect sign-in, step-up
  authentication, TOTP, and passkeys (WebAuthn). The specifications and
  the known deviations are listed in `AGENTS.md`.
- **Observability:** `livery_instrument_trace` opens a span for each
  request through `instrument_tracer`, passes on the W3C `traceparent`
  header, and records the usual HTTP attributes.
  `livery_instrument_metrics` records counters, gauges and histograms
  through `instrument_meter`, named as the OpenTelemetry HTTP server
  conventions say. Log lines carry `trace_id` and `span_id`.
- **Graceful shutdown:** `livery_drain` stops taking new streams, gives
  the requests in progress a time you choose to finish, then closes.
- **Built-in middleware:** `livery_request_id` sets or keeps
  `X-Request-ID`; `livery_body_limit` answers 413 to a body over its
  limit; `livery_timeout` answers 504 when a route takes longer than
  its deadline; `livery_access_log` writes one structured log line per
  request (where Cowboy uses a `cowboy_stream` handler). You add the
  ones you want to your middleware stack.

## 11. Performance principles

- Bodies stay iodata from the handler to the wire library; Livery does
  not flatten or re-encode them along the way.
- Header names are lowercased once, when the request comes in, so
  later lookups compare them as they are.
- Each request runs in a short-lived process with a small heap, and no
  shared server process sits in the way of a small request.
- A body is read as the handler asks for it: the client stays one flow
  window ahead of what the handler has read, and a body over
  `max_body` is answered `413`.
- `bench/` (`rebar3 as bench shell`, `livery_bench`) measures latency
  percentiles and throughput on a sample handler over H1, H2 and H3,
  and can fail a run whose p99 is more than 10 percent worse than a
  saved baseline. CI does not run it yet.

## 12. Out of scope

- HTTP/2 server push (PUSH_PROMISE): deprecated, and browsers have
  turned it off.
- The HTTP/2 priority tree: replaced by RFC 9218, and if it is ever
  supported, it belongs in `h2`.
- An HTTP/1.1 parser, HPACK, QPACK or QUIC of its own: these belong to
  the wire libraries.
- HTML templates, view helpers, an ORM: use the libraries you like
  alongside Livery.
- Its own JSON codec. Encode with OTP's `json` module, `thoas`, `jsx`
  or any other; `livery_resp:json/2,3` takes the encoded iodata.

## 13. Toward 1.0

Livery reaches 1.0 when all of these are true. Where each one stands:

1. **Done.** `livery:start_service/1` brings up H1, H2, and H3 on
   ports 443 and 80, all serving one set of handlers.
2. **Done.** `test/livery_parity_SUITE.erl` runs the same handler
   matrix against `livery_test_adapter`, `livery_h1`, `livery_h2` and
   `livery_h3`, and `livery_e2e_SUITE` runs a full journey over the
   H3, H2 and H1 chain.
3. **Not yet.** `h2spec`, QUIC interop (quiche-client, ngtcp2-client)
   and Autobahn suites passing in CI. The wire libraries run their own
   conformance suites; Livery's CI does not run these yet.
4. **In pieces.** A Keycloak-protected route, an `/openapi.json`, an
   MCP tool over Inspector, a WebSocket echo, an SSE feed and a
   WebTransport echo session each work and are tested on their own; one
   service showing them all together is not in this repository yet.
5. **In part.** `livery_instrument_trace` sets the HTTP semantic
   attributes and passes on `traceparent`; nothing here checks that the
   traces show up in Jaeger.
6. **Not yet.** The bench harness can fail a run whose p99 is 10
   percent worse than a baseline, but it does not run in CI.
7. **Done.** `rebar3 as check dialyzer` and `rebar3 as check xref`
   are clean, and CI enforces both.
8. **Outside this repository.** `erllama_server` runs against
   `livery:start_service/1` over the full H3, H2 and H1 chain: its CT
   suite passes over each protocol with the same handlers, NDJSON
   streaming on `/api/pull` and `/api/chat` works on each, and clients
   move up to H3 through Alt-Svc. That shows Livery can replace Cowboy
   in a real service.
