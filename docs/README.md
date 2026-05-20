# Livery Documentation

Livery is a modern Erlang web framework that serves one handler set
over HTTP/1.1, HTTP/2, and HTTP/3 from a single service runtime. The
wire layer (h1, h2, quic, ws) lives in sibling libraries; Livery
owns the developer surface: router, middleware, handlers, extractors,
observability.

These docs follow the [Diátaxis](https://diataxis.fr/) split:
**tutorials** teach, **how-to guides** solve a specific task,
**concepts** explain how things fit together, **reference** is the
exact API.

## Start here

| If you ... | Read |
|---|---|
| Need a one-paragraph pitch | [Overview](overview.md) |
| Want a hello-world service in 5 minutes | [Quickstart](quickstart.md) |
| Want to learn Livery from scratch | [Tutorials](#tutorials) |
| Have a specific task in mind | [How-to guides](#how-to-guides) |
| Want to understand the model | [Concepts](#concepts) |
| Want the exact API | [Reference](#reference) |

## Tutorials

Step-by-step, learning-oriented.

- [Your first service](tutorials/your-first-service.md)
- [Compose a middleware stack](tutorials/middleware-stack.md)
- [Stream a response](tutorials/streaming-responses.md)
- [Test your handlers](tutorials/testing-handlers.md)

## How-to guides

Task-oriented recipes. Each guide is a specific problem and its
solution.

**Reading requests**
- [Parse a JSON body](guides/parse-json-bodies.md)
- [Read query string parameters](guides/read-query-strings.md)
- [Read headers](guides/read-headers.md)
- [Extract a bearer token](guides/bearer-tokens.md)
- [Read a streaming request body](guides/read-streaming-body.md)

**Writing responses**
- [Return a streaming response](guides/stream-chunked.md)
- [Return Server-Sent Events](guides/server-sent-events.md)
- [Return trailers](guides/return-trailers.md)
- [Serve a file](guides/serve-a-file.md)
- [Send an empty or redirect response](guides/empty-and-redirects.md)

**Routing & middleware**
- [Mount a router on a service](guides/mount-a-router.md)
- [Write a custom middleware](guides/custom-middleware.md)
- [Cap request body size](guides/cap-body-size.md)
- [Add per-request deadlines](guides/add-deadlines.md)
- [Log every request](guides/log-requests.md)
- [Propagate request IDs](guides/propagate-request-ids.md)
- [Catch handler errors](guides/handler-errors.md)

**Operations**
- [Shut down gracefully](guides/graceful-shutdown.md)

**Testing and migration**
- [Test handlers without a socket](guides/test-handlers.md)
- [Migrate from Cowboy](guides/migrate-from-cowboy.md)

## Concepts

Explanation-oriented. Read these to understand why Livery is shaped
the way it is.

- [Architecture](concepts/architecture.md)
- [Request and response model](concepts/request-and-response.md)
- [The middleware pipeline](concepts/middleware-pipeline.md)
- [Routing](concepts/routing.md)
- [Request lifecycle](concepts/request-lifecycle.md)
- [Adapters](concepts/adapters.md)
- [Streaming and backpressure](concepts/streaming-and-backpressure.md)

For the long-form architecture write-up, see [design.md](design.md).

## Reference

Information-oriented. The exact API for each module is generated
from source by [ex_doc](https://hexdocs.pm/ex_doc); browse the
sidebar's "Modules" section, grouped as:

- **Public API:** `livery`
- **Request and response:** `livery_req`, `livery_resp`, `livery_ext`
- **Routing and middleware:** `livery_router`, `livery_middleware`
- **Built-in middleware:** `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- **Adapters:** `livery_adapter`, `livery_test_adapter`
- **Body reader:** `livery_body`
- **Runtime:** `livery_app`, `livery_sup`, `livery_req_proc`, `livery_req_sup`

## Project state

Livery is mid-rewrite. Phase 1 (the developer surface) is complete
and exercised end-to-end through the test adapter. The H1/H2/H3
wire adapters and `livery:start_service/1` land in Phases 2 to 4.
Track progress in [rewrite_plan.md](rewrite_plan.md).
