# Livery benchmarks

`livery_bench` drives keep-alive load against a reference handler
served by `livery_h1`, `livery_h2` (h2c), or `livery_h3`, and
reports latency percentiles and throughput. It also implements the
>10% p99 regression gate from the rewrite plan.

## Run

```
rebar3 as bench shell
1> livery_bench:run().                       %% H1, defaults
2> livery_bench:run(#{protocol => h3}).
3> livery_bench:run_all(#{connections => 100, duration_ms => 5000}).
```

Run it interactively (the example above) rather than with
`halt/0`: `run/1` stops the listener cleanly in its `after` clause,
whereas halting the VM mid-teardown logs spurious connection
crashes.

Options: `protocol` (`h1` | `h2` | `h3`, default `h1`),
`connections` (default 50), `duration_ms` (3000), `warmup_ms`
(500), `port` (0 = ephemeral). `run_all/0,1` runs all three
protocols and returns `[{Protocol, Metrics}]`.

`run/0,1` prints a report and returns a metrics map:

```erlang
#{protocol => h1, connections => 50, duration_ms => 3000,
  requests => N, reconnects => R, throughput_rps => F,
  p50_us => _, p90_us => _, p99_us => _, max_us => _}
```

`reconnects` counts connections re-established mid-run. For HTTP/2
this is expected: the wire library caps streams at 100 per
connection (a DoS guard), so the harness cycles the connection and
keeps going. H1/H3 keep one connection per worker and report 0.

## Indicative numbers (loopback, 100 conns, 5 s)

| Protocol | req/s | p50 | p99 |
|---|---|---|---|
| H1       | ~62k  | 2.0 ms | 4.3 ms |
| H2 (h2c) | ~48k  | 1.5 ms | 2.4 ms |
| H3       | ~12k  | 8.2 ms | 10.8 ms |

Loopback, single host (Apple silicon); absolute numbers are
host-specific. Use them only as a same-host before/after baseline,
not as cross-environment targets.

## p99 regression gate

Capture a baseline on your benchmark host and compare future runs:

```erlang
Baseline = livery_bench:run(#{connections => 100, duration_ms => 10000}),
%% ... later, on the same host ...
Current  = livery_bench:run(#{connections => 100, duration_ms => 10000}),
{ok, _} = livery_bench:compare(Baseline, Current).
```

`compare/2` returns `{ok, _}` when the current p99 is within 110% of
the baseline p99, or `{regressed, Detail}` otherwise. Percentile
numbers are host-specific, so generate the baseline where the gate
runs rather than committing fixed numbers.
