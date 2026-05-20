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
handler — a useful pattern until route mounting lands in the
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

## Notes

- These examples serve plain HTTP/1.1 so they run without
  certificates. For H2 over TLS and H3 over QUIC, add `https` and
  `http3` keys (with `cert`/`key`) to the `start_service/1` map; see
  `docs/concepts/architecture.md`.
- Benchmarks (wrk, h2load, quiche-client) against a reference
  handler run in docker-CI and are not part of this directory.
