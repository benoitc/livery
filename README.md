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
  <a href="docs/rewrite_plan.md">Design</a>
</p>

---

Livery is a BEAM-native web framework that serves the same router and
middleware over **HTTP/1.1, HTTP/2, and HTTP/3** from a single
runtime. WebSocket, WebTransport, Server-Sent Events, OpenAPI, MCP,
and OpenTelemetry-style observability are built-in modules. It is
written in the spirit of Axum + Tower + Hyper, on Erlang/OTP.

```erlang
Router = livery_router:compile([
    {<<"GET">>, <<"/">>, fun(_Req) ->
        livery_resp:text(200, <<"hello from livery">>)
    end},
    {<<"GET">>, <<"/users/:id">>, {users, show}}
]),

livery:start_service(#{
    http  => #{port => 80, redirect => https},
    https => #{port => 443, cert => Cert, key => Key, alpn => [h2, http1]},
    http3 => #{port => 443, cert => Cert, key => Key},
    router => Router,
    middleware => [{livery_request_id, undefined}, {livery_access_log, #{}}],
    alt_svc => advertise
}).
```

## Install

```erlang
%% rebar.config
{deps, [{livery, {git, "https://github.com/benoitc/livery.git", {branch, "main"}}}]}.
```

## Features

- **One handler, three wires** — write a handler once; serve it over
  H1, H2, and H3 with shared routing, middleware, and Alt-Svc upgrade.
- **Tower-style middleware** — value-based `call(Req, Next, State)`
  pipelines, composable per service or per route.
- **Streaming** — chunked, SSE, NDJSON, WebSocket and WebTransport
  over H2/H3, and file responses with byte ranges.
- **OpenAPI** — generate a 3.1 document from routes, serve Redoc or
  Swagger UI, and validate request bodies against a JSON-Schema subset.
- **MCP** — serve the Model Context Protocol Streamable HTTP transport
  on the main listener.
- **Observability & auth** — OpenTelemetry-style traces/metrics,
  trace-correlated logs, JWT/JWKS/OIDC, signed sessions, introspection.

## Documentation

Full guides, tutorials, and the generated API reference live at
**<https://benoitc.github.io/livery/>**. For contributors, see
[AGENTS.md](AGENTS.md).

## License

Apache-2.0.
