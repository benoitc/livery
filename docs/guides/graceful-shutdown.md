# How to shut down gracefully

On deploy or scale-down you want to stop a service without cutting
off requests that are mid-flight: finish them, refuse new ones, then
close. `livery:drain/2` does this, where `livery:stop_service/1`
would cut in-flight requests off.

## Drain instead of stopping

```erlang
{ok, Pid} = livery:start_service(#{http => #{port => 8080}, router => R}),
%% ... serving ...
ok = livery:drain(Pid, #{timeout => 30000}).
```

`drain/2`:

1. **Stops accepting**: closes the listen sockets so no new
   connections are taken. Connections already open keep serving.
2. **Waits** up to `timeout` (default 30s) for the requests already
   in flight to finish.
3. **Stops** the service.

It returns `ok` once everything drained, or `{error, timeout}` if
the window elapsed with requests still running. Either way the
service is stopped when `drain/2` returns.

`livery:stop_service/1` remains the immediate, non-graceful stop; it
cuts off in-flight requests.

## Wire it into shutdown

Call `drain/2` from your application's `stop/1`, or from a SIGTERM
handler, before the node halts:

```erlang
stop(_State) ->
    _ = livery:drain(whereis(my_service), #{timeout => 25000}),
    ok.
```

Pick a timeout shorter than your orchestrator's kill grace period
(e.g. Kubernetes `terminationGracePeriodSeconds`) so the drain
finishes before a hard kill.

## Notes

- In-flight requests are counted node-wide (every request runs under
  one shared supervisor). On a single-service node this is exactly
  that service's requests; on a multi-service node `drain/2` waits
  for all of them. `livery_drain:in_flight/0` reports the current
  count.
- "Stop accepting" closes the listen socket; it does not send GOAWAY
  on existing keep-alive connections, so a client reusing an open
  connection can still send one more request until the drain
  completes.

## See also

- Concept: [Request lifecycle](../concepts/request-lifecycle.md)
- Reference: `livery_drain`, `livery`
