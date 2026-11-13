# How to export Prometheus metrics

When you run a service in production you want Prometheus to scrape
its metrics at `/metrics`. Livery records HTTP server metrics
through the `livery_instrument_metrics` middleware and exposes them
with the `livery_metrics` handler. You add the middleware to the
stack and mount the handler on a route.

## Add the middleware and mount the handler

```erlang
R1 = livery_router:add('GET', <<"/metrics">>, livery_metrics:handler(), #{}, R0),
livery:start_service(#{
    router => R1,
    middleware => [{livery_instrument_metrics, #{}}]
}).
```

`GET /metrics` returns the registered metrics in Prometheus text
format with `Content-Type: text/plain; version=0.0.4; charset=utf-8`.

## What is exported

`livery_instrument_metrics` records the OpenTelemetry HTTP server
metrics:

- `http.server.active_requests` (gauge): requests in progress,
  exported as `http_server_active_requests`.
- `http.server.request.duration` (histogram, seconds): request
  latency, exported as `http_server_request_duration` with
  `_bucket`/`_sum`/`_count` series.

The request attributes become labels:

```
http_server_request_duration_count{http_request_method="GET",http_response_status_code="200",network_protocol_name="http/1.1",url_scheme="http"} 1
```

Any other metric your app registers through the `instrument` library
is exported too. `livery_metrics:handler()` renders the whole
`instrument` registry.

## Notes

- Prometheus names cannot hold dots, so they become underscores.
- A metric shows up after its first request, not as a zero before.

## See also

- Reference: `livery_metrics`, `livery_instrument_metrics`
- Guide: [Add health and readiness checks](health-checks.md)
