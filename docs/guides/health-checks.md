# How to add health and readiness checks

An orchestrator (Kubernetes, a load balancer) needs liveness and
readiness probes: is the process up, and is it ready to take
traffic? Mount the `livery_health` handlers on routes to answer both.

## Mount the handlers

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

`livery_health:live()` always answers `200 {"status":"ok"}`. Use it
for the liveness probe; it only signals that the process is running.

## Readiness

`livery_health:ready(Checks)` runs each `{Name, Fun}` check. A check
passes when its `Fun()` returns `ok`; any other return or a raised
exception counts as a failure.

- All pass -> `200 {"status":"ok"}`.
- Any fail -> `503 {"status":"unavailable","failed":["db"]}` listing
  the failed names.

## Notes

- `ready([])` is always ready.
- Checks run synchronously in the request process, so keep them fast
  (wrap slow dependencies with your own timeout).

## See also

- Reference: `livery_health`
- Guide: [Export Prometheus metrics](export-metrics.md)
