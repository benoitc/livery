# How to add health and readiness checks

## Problem

Your orchestrator - Kubernetes, a load balancer, whatever sits in
front - wants to ask your service two different questions. Is the
process even up? And is it actually ready to take traffic? Those are
the liveness and readiness probes, and you need an endpoint for each.

## Solution

Mount the ready-made `livery_health` handlers on a couple of routes:

```erlang
R0 = livery_router:new(),
R1 = livery_router:add('GET', <<"/healthz">>, livery_health:live(), #{}, R0),
R2 = livery_router:add(
    'GET', <<"/readyz">>,
    livery_health:ready([
        {<<"db">>, fun() -> my_db:ping() end},
        {<<"cache">>, fun() -> my_cache:ping() end}
    ]),
    #{}, R1
).
```

## Liveness

`livery_health:live()` always answers `200 {"status":"ok"}`. That is
exactly what you want for a liveness probe: it says nothing more than
"the process is running", which is the only thing liveness should
care about.

## Readiness

Readiness is where it gets interesting. `livery_health:ready(Checks)`
runs each `{Name, Fun}` check in turn. A check passes when its `Fun()`
returns `ok`; anything else, or a raised exception, counts as a
failure.

- All pass -> `200 {"status":"ok"}`.
- Any fail -> `503 {"status":"unavailable","failed":["db"]}` listing the
  failed names.

`ready([])` is always ready. One thing to keep in mind: the checks
run synchronously in the request process, so keep them quick. If a
dependency can be slow, wrap it in a timeout of your own rather than
letting the probe hang.

## See also

- Reference: `livery_health`
- Recipe: [Export Prometheus metrics](export-metrics.md)
