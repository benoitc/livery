# Livery examples

Runnable example services. Compile them with the `examples` profile:

```
rebar3 as examples compile
```

Then start one from a shell (`rebar3 as examples shell`):

```erlang
{ok, Pid} = livery_example_api:start(8080).
```

## `livery_example_api`

REST + path params + SSE + NDJSON + an OpenAPI document, served over
HTTP/1.1 on one port. `livery:start_service/1` takes a single
handler, so the example drives `livery_router` from inside that
handler - a useful pattern until route mounting lands in the
service runtime.

```
curl http://127.0.0.1:8080/            # hello, world
curl http://127.0.0.1:8080/hi/ada      # hello, ada
curl http://127.0.0.1:8080/events      # text/event-stream
curl http://127.0.0.1:8080/ticks       # application/x-ndjson
curl http://127.0.0.1:8080/openapi.json
```

## `livery_example_ws`

A WebSocket echo handler. Connect any WebSocket client to
`ws://127.0.0.1:8081/`; every text/binary frame is echoed back.
The same handler accepts WebSocket over H2/H3 when the service is
started with a TLS/QUIC listener and extended CONNECT enabled.

## `livery_example_complete`

The end-to-end notes service from the [Build a complete
service](../docs/tutorials/build-a-complete-service.md) tutorial: a
service, a router with path params, a service-wide and a per-route
middleware, JSON CRUD, an SSE feed, and a WebSocket echo. Start it with
`livery_example_complete:start(8080)`, or `start_tls/1` to serve H1, H2,
and H3 at once from the vendored `test/certs`.

```
curl http://127.0.0.1:8080/notes
curl -XPOST --data '{"text":"buy bread"}' http://127.0.0.1:8080/notes
curl http://127.0.0.1:8080/notes/1
curl -N http://127.0.0.1:8080/events
```

## `livery_example_adapter`

A minimal custom adapter, the companion to the "write your own adapter"
section of the same tutorial. It implements the `livery_adapter`
behaviour and runs the real per-request worker, but captures the
response in ETS instead of writing to a socket, so the wiring is easy to
read. `test/livery_example_adapter_tests.erl` drives it end to end.

## `livery_example_stream`

The receive-driven streaming companion to the [Streaming and
backpressure](../docs/concepts/streaming-and-backpressure.md) concept
doc. A `/clock` endpoint returns Server-Sent Events, one per second, from
a named `tick/3` producer that loops on `receive` and stops on client
disconnect. Start it with `livery_example_stream:start(8080)` and watch
with `curl -N http://127.0.0.1:8080/clock`.
`test/livery_example_stream_tests.erl` drives the producer with a tiny
interval.

## Notes

- These examples serve plain HTTP/1.1 so they run without
  certificates. For H2 over TLS and H3 over QUIC, add `https` and
  `http3` keys (with `cert`/`key`) to the `start_service/1` map; see
  `docs/concepts/architecture.md`.
- Benchmarks (wrk, h2load, quiche-client) against a reference
  handler run in docker-CI and are not part of this directory.
