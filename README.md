# Livery

**One handler set. Every version of HTTP.**

Livery is a BEAM-native web framework that serves the same router and
middleware over **HTTP/1.1, HTTP/2, and HTTP/3** from a single runtime.
WebSocket, WebTransport, Server-Sent Events, OpenAPI, MCP, and an
OpenTelemetry-style observability layer are built-in modules. It is
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

## What else is built in

- **OpenAPI** — generate a 3.1 document from routes, serve Redoc or
  Swagger UI, validate request bodies against a JSON-Schema subset.
- **MCP** — serve the Model Context Protocol Streamable HTTP transport on
  the main listener.
- **Auth** — JWT/JWKS/OIDC bearer middleware, signed session cookies,
  RFC 7662 token introspection.
- **Observability** — OpenTelemetry-style traces and metrics, with
  trace-correlated logs.

## Documentation

The docs live in [`docs/`](docs/README.md) and follow the Diataxis split:

- [Quickstart](docs/quickstart.md) and [Overview](docs/overview.md)
- [Tutorials](docs/README.md#tutorials) — learn Livery step by step
- [How-to guides](docs/README.md#how-to-guides) — task-focused recipes
- [Concepts](docs/README.md#concepts) and [Design notes](docs/design.md)

Build the API reference locally with `rebar3 ex_doc` (output under
`doc/`). For contributors, see [AGENTS.md](AGENTS.md).

## License

Apache-2.0.
