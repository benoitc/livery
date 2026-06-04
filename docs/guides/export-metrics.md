# How to export Prometheus metrics

## Problem

You are running a Prometheus setup, and you want it to scrape your
service like any other target: hit `/metrics`, get request rates and
latencies back in the format it expects.

## Solution

Livery records HTTP server metrics through the
`livery_instrument_metrics` middleware and serves them with the
`livery_metrics` handler. So you do two things: add the middleware to
the stack, and mount the handler at `/metrics`:

```erlang
R1 = livery_router:add('GET', <<"/metrics">>, livery_metrics:handler(), #{}, R0),
livery:start_service(#{
    router => R1,
    middleware => [{livery_instrument_metrics, #{}}]
}).
```

`GET /metrics` returns the registered metrics in Prometheus text format
with `Content-Type: text/plain; version=0.0.4; charset=utf-8`.

## What is exported

`livery_instrument_metrics` records the OpenTelemetry HTTP server
metrics:

- `http.server.active_requests` (gauge) - concurrent in-flight requests.
- `http.server.request.duration` (histogram, seconds) - request latency
  with `_bucket`/`_sum`/`_count` series.

Anything else your app registers through the `instrument` library
shows up too, since `livery_metrics:handler()` just renders the whole
`instrument` registry. Names go out verbatim, so the dots in the
OpenTelemetry names stay exactly as they are.

## See also

- Reference: `livery_metrics`, `livery_instrument_metrics`
- Recipe: [Add health and readiness checks](health-checks.md)
