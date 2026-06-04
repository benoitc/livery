# How to shut down gracefully

## Problem

You are deploying a new version, or scaling down a node, and right
now there are requests in flight. You do not want to drop them on
the floor. What you want is simple: finish the work already started,
politely refuse anything new, then close the door.

## Solution

Use `livery:drain/2` instead of `livery:stop_service/1`:

```erlang
{ok, Pid} = livery:start_service(#{http => #{port => 8080}, router => R}),
%% ... serving ...
ok = livery:drain(Pid, #{timeout => 30000}).
```

`drain/2`:

1. **Stops accepting** - it closes the listen sockets, so no new
   connection is taken. Connections already open keep serving.
2. **Waits** up to `timeout` (30s by default) for the requests
   already in flight to finish.
3. **Stops** the service.

You get back `ok` once everything has drained, or `{error, timeout}`
if the window ran out with requests still running. Either way, the
service is stopped by the time `drain/2` returns.

If you want the brutal version, `livery:stop_service/1` is still
there: it stops immediately and cuts off in-flight requests.

## Wiring it into shutdown

The natural place to call `drain/2` is your application's `stop/1`,
or a SIGTERM handler, right before the node halts:

```erlang
stop(_State) ->
    _ = livery:drain(whereis(my_service), #{timeout => 25000}),
    ok.
```

One tip: pick a timeout shorter than your orchestrator's kill grace
period (Kubernetes `terminationGracePeriodSeconds`, for instance) so
the drain finishes on its own before a hard kill steps in.

## Notes

- In-flight requests are counted node-wide, because every request
  runs under one shared supervisor. On a single-service node that is
  exactly your service's requests; on a multi-service node `drain/2`
  waits for all of them. `livery_drain:in_flight/0` tells you the
  current count.
- "Stop accepting" closes the listen socket, but it does not send
  GOAWAY on existing keep-alive connections. So a client reusing an
  open connection can still slip in one more request until the drain
  completes.

## See also

- Concept: [Request lifecycle](../concepts/request-lifecycle.md)
- Reference: `livery_drain`, `livery`
