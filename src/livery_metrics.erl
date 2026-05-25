-module(livery_metrics).
-moduledoc """
Prometheus `/metrics` handler.

Returns a handler that renders the `instrument` registry in Prometheus
text exposition format. Livery's `livery_instrument_metrics` middleware
already records HTTP server metrics into that registry; mount this on a
route to expose them:

```erlang
R1 = livery_router:add('GET', <<"/metrics">>, livery_metrics:handler(), #{}, R0).
```

The body and `Content-Type`
(`text/plain; version=0.0.4; charset=utf-8`) come from
`instrument_prometheus`. Requires the `instrument` application to be
running (it is, as a Livery dependency).
""".

-export([handler/0]).

-doc "Handler that exposes registered metrics in Prometheus format.".
-spec handler() -> livery_middleware:handler().
handler() ->
    fun(_Req) ->
        livery_resp:text(
            200,
            [{<<"content-type">>, instrument_prometheus:content_type()}],
            instrument_prometheus:format()
        )
    end.
