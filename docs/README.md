# Livery Documentation

Livery is an Erlang web framework that serves one set of handlers
over HTTP/1.1, HTTP/2, and HTTP/3 from a single service. The
protocols themselves (h1, h2, quic, ws) live in separate libraries;
Livery is the part you write code against: router, middleware,
handlers, extractors, observability.

These docs follow the [Diátaxis](https://diataxis.fr/) split:
**tutorials** teach, **how-to guides** solve a specific task,
**concepts** explain how things fit together, **reference** is the
exact API.

## Start here

| If you ... | Read |
|---|---|
| Want a one-paragraph summary | [Overview](overview.md) |
| Want a hello-world service in 5 minutes | [Quickstart](quickstart.md) |
| Want to learn Livery from scratch | [Tutorials](#tutorials) |
| Have a specific task in mind | [How-to guides](#how-to-guides) |
| Want to understand the model | [Concepts](#concepts) |
| Want the exact API | [Reference](#reference) |

## Tutorials

Step by step, to learn Livery.

- [Your first service](tutorials/your-first-service.md)
- [Compose a middleware stack](tutorials/middleware-stack.md)
- [Stream a response](tutorials/streaming-responses.md)
- [Test your handlers](tutorials/testing-handlers.md)
- [Call another service](tutorials/call-a-service.md)
- [Build a complete service](tutorials/build-a-complete-service.md)

## How-to guides

Recipes. Each guide takes one task and shows how to do it.

**Reading requests**
- [Parse a JSON body](guides/parse-json-bodies.md)
- [Read query string parameters](guides/read-query-strings.md)
- [Read headers](guides/read-headers.md)
- [Extract a bearer token](guides/bearer-tokens.md)
- [Verify opaque tokens with introspection](guides/token-introspection.md)
- [Use signed session cookies](guides/session-cookies.md)
- [Read a streaming request body](guides/read-streaming-body.md)

**Writing responses**
- [Return a streaming response](guides/stream-chunked.md)
- [Return Server-Sent Events](guides/server-sent-events.md)
- [Return trailers](guides/return-trailers.md)
- [Send Early Hints](guides/early-hints.md)
- [Serve a file](guides/serve-a-file.md)
- [Send an empty or redirect response](guides/empty-and-redirects.md)

**Routing & middleware**
- [Mount a router on a service](guides/mount-a-router.md)
- [Handle QUERY requests](guides/query-method.md)
- [Write a custom middleware](guides/custom-middleware.md)
- [Cap request body size](guides/cap-body-size.md)
- [Add per-request deadlines](guides/add-deadlines.md)
- [Log every request](guides/log-requests.md)
- [Propagate request IDs](guides/propagate-request-ids.md)
- [Catch handler errors](guides/handler-errors.md)
- [Cancel work when the client disconnects](guides/cancel-on-disconnect.md)
- [Generate OpenAPI docs and validate requests](guides/openapi-and-validation.md)
- [Serve MCP tools](guides/serve-mcp-tools.md)
- [Serve A2A agents](guides/serve-a2a-agents.md)
- [Serve WebTransport](guides/serve-webtransport.md)

**Calling out**
- [Make outbound HTTP requests](guides/make-http-requests.md)
- [Load-balance outbound requests](guides/load-balance-requests.md)
- [Use a cookie jar](guides/use-a-cookie-jar.md)

**Operations**
- [Shut down gracefully](guides/graceful-shutdown.md)

**Testing and migration**
- [Test handlers without a socket](guides/test-handlers.md)
- [Migrate from Cowboy](guides/migrate-from-cowboy.md)

## Concepts

Explanations. Read these to understand why Livery works the way it
does.

- [Architecture](concepts/architecture.md)
- [Request and response model](concepts/request-and-response.md)
- [The middleware pipeline](concepts/middleware-pipeline.md)
- [Routing](concepts/routing.md)
- [Request lifecycle](concepts/request-lifecycle.md)
- [Adapters](concepts/adapters.md)
- [Streaming and backpressure](concepts/streaming-and-backpressure.md)

For the long-form architecture write-up, see [design.md](design.md).

## Reference

For looking things up. [ex_doc](https://hexdocs.pm/ex_doc) generates
the exact API of each module from the source; browse the "Modules"
section of the sidebar, grouped as:

- **Public API:** `livery`
- **Request and response:** `livery_req`, `livery_resp`, `livery_ext`
- **Routing and middleware:** `livery_router`, `livery_middleware`
- **Built-in middleware:** `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- **Adapters:** `livery_adapter`, `livery_test_adapter`
- **Body reader:** `livery_body`
- **Runtime:** `livery_app`, `livery_sup`, `livery_req_proc`, `livery_req_sup`

## Ecosystem

Companion libraries built on Livery, each in its own repo:

- [livery_grpc](https://github.com/benoitc/livery_grpc): gRPC server and
  client on top of Livery's HTTP/2 support. All four call types, deadlines, gRPC-Web,
  server reflection, and the standard health service.
- [livery_s3](https://github.com/benoitc/livery_s3): S3-compatible object
  storage client on the Livery HTTP client. AWS SigV4 signing, multipart
  uploads, presigned URLs; works with AWS S3, Garage, MinIO, Ceph, and Wasabi.
- [livery_stripe](https://github.com/benoitc/livery_stripe): Stripe API
  client on the Livery HTTP client. Customers, subscriptions, Checkout, the
  Billing Portal, and webhook verification.

## Project state

The API, the H1, H2 and H3 adapters, and `livery:start_service/1`
are all in place and tested end to end (the parity suite runs the same
handlers through every adapter and compares what comes back).
See [design.md](design.md) for the long-form architecture.
