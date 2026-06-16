<p align="center">
  <img src="site/assets/livery-mark.svg" alt="Livery" width="96" height="96">
</p>

<h1 align="center">Livery</h1>

<p align="center">
  One handler set. Every version of HTTP.
</p>

<p align="center">
  <a href="https://benoitc.github.io/livery/">Website</a> ·
  <a href="https://benoitc.github.io/livery/api/index.html">Docs</a> ·
  <a href="docs/design.md">Design</a>
</p>

---

Livery is a BEAM-native web framework that serves the same router and
middleware over **HTTP/1.1, HTTP/2, and HTTP/3** from a single
runtime. WebSocket, WebTransport, Server-Sent Events, OpenAPI, MCP,
and OpenTelemetry-style observability are built-in modules. It is
written in the spirit of Axum + Tower + Hyper, on Erlang/OTP.

## Install

```erlang
%% rebar.config
{deps, [{livery, {git, "https://github.com/benoitc/livery.git", {branch, "main"}}}]}.
```

## Hello, world

A handler takes a request value and returns a response value. Compile a
router, start a service, and you are serving:

```erlang
Router = livery_router:compile([
    {<<"GET">>, <<"/">>, fun(_Req) -> livery_resp:text(200, <<"hello">>) end}
]),
{ok, _Pid} = livery:start_service(#{http => #{port => 8080}, router => Router}).
```

```console
$ curl localhost:8080/
hello
```

Run it now: `rebar3 shell`, paste the two expressions, then `curl`.

## Route, with path params and JSON

```erlang
show_user(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    livery_resp:json(200, json:encode(#{id => Id, name => <<"Ada">>})).

Router = livery_router:compile([
    {<<"GET">>,  <<"/users/:id">>, fun show_user/1},
    {<<"POST">>, <<"/users">>,     {users, create}}   %% {Module, Function}
]).
```

## Stack middleware (Tower/Axum style)

Middleware is a continuation over immutable values: `call(Req, Next,
State)`. Attach it service-wide or per route.

```erlang
livery:start_service(#{
    http   => #{port => 8080},
    router => Router,
    middleware => [
        {livery_request_id, undefined},
        {livery_access_log, #{}},
        {livery_body_limit, #{max => 1048576}}
    ]
}).
```

## One service, three protocols

The same router and middleware over H1, H2, and H3, advertising H3 via
`Alt-Svc`:

```erlang
livery:start_service(#{
    http   => #{port => 80},
    https  => #{port => 443, cert => Cert, key => Key},
    http3  => #{port => 443, cert => Cert, key => Key},
    router => Router,
    alt_svc => advertise
}).
```

Need just one protocol? `livery:start_listener(livery_h1, #{port => 8080,
router => Router})`.

## Call other services

The client mirrors the middleware model outbound: stack timeouts, retries,
a circuit breaker, or load balancing around a request.

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    stack    => [livery_client:timeout(5000), livery_client:retry(#{max => 3})]
}),
{ok, Resp} = livery_client:get(Client, <<"/health">>),
200 = livery_client:status(Resp).
```

## Stream a response

```erlang
events(_Req) ->
    livery_resp:sse(200, fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>})
    end).
```

Chunked bodies, NDJSON, file responses with byte ranges, WebSocket and
WebTransport over H2/H3 work the same way.

## Early-response semantics

Sometimes a handler answers before it has read the request body, like
rejecting an oversized upload with a `413`. On HTTP/1.1 the connection
would normally close right after the response, and with a large upload
still in flight the close can reach the client before it reads your
`413`, so the client sees a reset instead.

Livery handles this for you. When you return a full response before the
body is drained, it reads and discards the rest of the inbound body
before closing, so the client gets the response:

```erlang
reject(_Req) ->
    livery_resp:json(413, [], <<"{\"error\":\"too_big\"}">>).
```

The drain is bounded by a budget you set per listener (defaults to no
byte cap and a 30 s deadline):

```erlang
{ok, _} = livery:start_listener(livery_h1, #{
    port => 8080,
    early_response_drain => {16#400000, 5000},  %% 4 MiB / 5 s
    handler => fun reject/1
}).
```

Override it for a single response, or disable the drain with `none`:

```erlang
livery_resp:json(413, [], Body, #{early_response_drain => {16#400000, 5000}}).
```

The per-response override applies to full responses. Streaming responses
(SSE, NDJSON, chunked, files) use the listener budget.

## Features

- **One handler, three wires** — write a handler once; serve it over
  H1, H2, and H3 with shared routing, middleware, and Alt-Svc upgrade.
- **Tower-style middleware** — value-based `call(Req, Next, State)`
  pipelines, composable per service or per route, in both directions
  (server-inbound and the outbound `livery_client`).
- **Streaming** — chunked, SSE, NDJSON, WebSocket and WebTransport
  over H2/H3, and file responses with byte ranges.
- **OpenAPI** — generate a 3.1 document from routes, serve Redoc or
  Swagger UI, and validate request bodies against a JSON-Schema subset.
- **MCP** — serve the Model Context Protocol Streamable HTTP transport
  on the main listener.
- **Observability & auth** — OpenTelemetry-style traces/metrics,
  trace-correlated logs, JWT/JWKS/OIDC, signed sessions, introspection.

## Ecosystem

Companion libraries built on Livery, each in its own repo:

- **[livery_grpc](https://github.com/benoitc/livery_grpc)** - gRPC server and
  client on Livery's HTTP/2 stack: all four call types, deadlines, gRPC-Web,
  server reflection, and the standard health service.
- **[livery_s3](https://github.com/benoitc/livery_s3)** - S3-compatible object
  storage client on the Livery HTTP client: AWS SigV4 signing, multipart
  uploads, and presigned URLs, for AWS S3, Garage, MinIO, Ceph, and Wasabi.
- **[livery_stripe](https://github.com/benoitc/livery_stripe)** - Stripe API
  client on the Livery HTTP client: customers, subscriptions, Checkout, the
  Billing Portal, and webhook verification.

## Documentation

Full guides, tutorials, and the generated API reference live at
**<https://benoitc.github.io/livery/>**. The same content is in the repo
under [`docs/`](docs/README.md): start with the
[Quickstart](docs/quickstart.md), then the
[tutorials](docs/README.md#tutorials) and
[how-to guides](docs/README.md#how-to-guides). For contributors, see
[AGENTS.md](AGENTS.md).

## Sponsors

<a href="https://enki-multimedia.eu"><img src="site/assets/enki-multimedia.svg" alt="Enki Multimedia" height="50" /></a>

Livery is developed and maintained by [Enki Multimedia](https://enki-multimedia.eu).
If your company relies on it, [reach out](mailto:benoitc@enki-multimedia.eu)
for sponsored support, or sponsor its maintenance via
[GitHub Sponsors](https://github.com/sponsors/benoitc).

## License

Apache-2.0.
