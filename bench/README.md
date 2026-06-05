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

`reconnects` counts connections re-established mid-run. All three
protocols keep one connection per worker and report 0 under steady
load; a non-zero count means requests were failing and the worker had
to reconnect.

## Indicative numbers (loopback, 100 conns, 5 s)

| Protocol | req/s | p50 | p99 |
|---|---|---|---|
| H1       | ~79k  | 1.0 ms | 4.7 ms |
| H2 (h2c) | ~75k  | 1.3 ms | 2.8 ms |
| H3       | ~16k  | 5.8 ms | 6.6 ms |

Loopback, single host (Apple silicon); absolute numbers are
host-specific. Use them only as a same-host before/after baseline,
not as cross-environment targets.

## Cross-server comparison (livery vs cowboy vs bandit)

`bench/compare.sh` benchmarks the same `GET / -> {"ok":true}` endpoint on
**livery**, **cowboy**, and **bandit** over HTTP/1.1 (cleartext) and
HTTP/2 (over TLS, ALPN-negotiated - the way h2 is actually deployed). Each
server runs out of process on its own port and is driven by an external
client ([`wrk`](https://github.com/wg/wrk) for H1,
[`h2load`](https://nghttp2.org/documentation/h2load-howto.html) for H2),
so all three are treated identically and the load generator never shares a
VM with the server under test. Livery and cowboy boot under one BEAM (via
`livery_bench:serve/3`); bandit boots under Elixir, pulling itself in with
`Mix.install` on first run (needs network and a one-time compile). TLS uses
the vendored self-signed test certs.

```
bench/compare.sh                       # 4 threads, 64 conns, 10s
DUR=20 CONN=128 THREADS=8 bench/compare.sh
```

Requires `wrk`, `h2load`, `elixir`, `rebar3`, and `curl` on the PATH.

Indicative numbers (loopback, Apple silicon, 4t / 64c / 8s):

**HTTP/1.1 (cleartext, wrk)**

| Server | req/s | p50 | p99 |
|---|---|---|---|
| livery | ~130k | 0.45 ms | 1.26 ms |
| cowboy | ~142k | 0.36 ms | 1.11 ms |
| bandit | ~147k | 0.34 ms | 1.30 ms |

**HTTP/2 over TLS (h2load, 32 streams/conn)**

| Server | req/s | errors |
|---|---|---|
| livery | ~154k | 0 |
| bandit | ~139k | 0 |
| cowboy | ~80k | resets under load |

**HTTP/3 (livery only, in-VM quic_h3)**

| Server | req/s | p50 | p99 |
|---|---|---|---|
| livery | ~16k | 3.7 ms | 4.6 ms |

Cowboy and bandit do not speak HTTP/3, and external h3 load tools
(`h2load` QUIC) do not interoperate with the self-signed QUIC listener
here, so H3 is measured with livery's own in-VM `quic_h3` driver and is
not directly comparable to the external H1/H2 figures (different load
path, and QUIC over loopback is bounded by the round trip - measure H3
with a native client off-box for absolute numbers).

Same-host, single run; absolute numbers are host-specific. Notes:

- **H1**: livery now coalesces full responses into a single
  `content-length` write (`livery_h1:send_full/5` -> `h1:respond/5`);
  earlier it sent them chunked over two writes, which cost ~20% here. The
  small remaining gap is largely livery's worker process per request (the
  `cowboy_loop` analogue), traded for the ability to block/`receive` in a
  handler.
- **H2**: livery is fastest of the three over TLS (its H2 adapter already
  coalesces via `h2:respond/5`). Cowboy's HTTP/2 returns fewer req/s and
  resets a fraction of streams under `h2load`'s stream churn (its built-in
  HTTP/2 flow-rate protection), so its number is noisier.

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

## Stress vs. benchmark

This harness measures throughput and latency under load. Stability
under concurrency is checked separately by
`test/livery_stress_SUITE.erl`, a bounded Common Test suite that
hammers the H1 adapter (sustained keep-alive load and connection
churn) and asserts the invariants that matter: zero errors, the
per-request workers drain back to zero (`livery_drain:in_flight/0`,
i.e. no leak), and the service stays responsive. It runs in CI; use
this `bench` harness for heavy, long-running soak testing.
