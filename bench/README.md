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

`bench/compare.sh` benchmarks **livery**, **cowboy**, and **bandit** over
HTTP/1.1 (cleartext) and HTTP/2 (over TLS, ALPN-negotiated - the way h2 is
actually deployed), across a few realistic workloads rather than one
static GET:

| Workload | request | what it stresses |
|---|---|---|
| `tiny` | `GET /` | accept + framing overhead |
| `bytes1k`/`10k`/`100k` | `GET /bytes/<n>` | response write path at 1/10/100 KiB |
| `echo` | `POST /echo` | body read + decode + encode (the common API path) |

The sized payloads are built once and served from a cache (not rebuilt per
request), so the `bytes*` rows measure the response/write path rather than
`binary:copy`/GC.

Each server runs out of process on its own port and is driven by an
external client ([`wrk`](https://github.com/wg/wrk) for H1,
[`h2load`](https://nghttp2.org/documentation/h2load-howto.html) for H2),
so all three are treated identically and the load generator never shares a
VM with the server. Livery and cowboy boot under one BEAM (via
`livery_bench:serve/3`); bandit boots under Elixir, pulling itself in with
`Mix.install` on first run (needs network and a one-time compile). TLS uses
the vendored self-signed test certs. The script prints a per-run line and a
summary table per protocol.

```
bench/compare.sh                       # full matrix, 4 threads, 64 conns, 10s
DUR=20 CONN=128 bench/compare.sh
SWEEP=1 bench/compare.sh               # also a concurrency sweep (16/64/256/1024)
```

Requires `wrk`, `h2load`, `elixir`, `rebar3`, and `curl` on the PATH.

Indicative numbers (loopback, Apple silicon, 4t / 64c, req/s):

**HTTP/1.1 (cleartext, wrk)**

| Server | tiny | 1 KiB | 10 KiB | 100 KiB | echo |
|---|---|---|---|---|---|
| livery | ~119k | ~113k | ~105k | ~57k | ~106k |
| cowboy | ~133k | ~137k | ~132k | ~61k | ~130k |
| bandit | ~145k | ~144k | ~139k | ~57k | ~139k |

**HTTP/2 over TLS (h2load, 32 streams/conn)**

| Server | tiny | 1 KiB | 10 KiB | 100 KiB | echo |
|---|---|---|---|---|---|
| livery | ~121k | ~122k | ~116k | ~29k | ~110k |
| cowboy | ~80k | ~80k | ~80k | ~80k | ~40k |
| bandit | ~120k | ~107k | ~103k | ~61k | ~104k |

**HTTP/3 (livery only, in-VM quic_h3)**: ~15k req/s. Cowboy and bandit do
not speak HTTP/3, and external h3 load tools (`h2load` QUIC) do not
interoperate with the self-signed QUIC listener here, so H3 uses livery's
own in-VM `quic_h3` driver and is not comparable to the external H1/H2
figures (different load path; QUIC over loopback is bounded by the round
trip - measure off-box with a native client for absolute numbers).

Same-host, single runs; absolute numbers are host-specific and vary run to
run (cowboy's HTTP/2 in particular swings under `h2load`'s churn). What
holds across runs:

- **H1 large bodies: livery is competitive.** At 100 KiB the three are
  within noise (~57-61k), with livery on par - its `send_full/5`
  coalescing puts the full response in one `content-length` write.
- **H1 tiny GET: a ~10-15% gap** that traces to livery's worker process
  per request (the `cowboy_loop` analogue, traded for the ability to
  block/`receive` in a handler).
- **H2 large bodies: livery is slower** (~29k @ 100 KiB vs bandit ~61k),
  a real cost in the H2 body-send path (DATA-frame chunking / flow control
  / TLS writes), not allocation and not disconnect handling - a known
  lead to chase upstream.
- **livery's HTTP/2 `echo` beats cowboy's** (~110k vs ~40k): cowboy's h2
  POST path is its weak spot here.

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
