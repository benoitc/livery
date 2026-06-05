#!/usr/bin/env bash
#
# Fair cross-server HTTP/1.1 benchmark: livery vs cowboy vs bandit.
#
# Each server runs out of process on its own port and is driven by `wrk`,
# so all three are treated identically and the load generator never shares
# a VM with the server under test. Livery and cowboy boot under one BEAM
# (via livery_bench:serve/3 on the bench profile code path); bandit boots
# under Elixir (Mix.install pulls it on first run, needs network).
#
# Usage:
#   bench/compare.sh                 # 4 threads, 64 conns, 10s
#   DUR=20 CONN=128 THREADS=8 bench/compare.sh
#
# Requires: wrk, elixir, rebar3 (and curl).

set -euo pipefail
cd "$(dirname "$0")/.."

DUR="${DUR:-10}"
CONN="${CONN:-64}"
THREADS="${THREADS:-4}"
LPORT="${LPORT:-9101}"
CPORT="${CPORT:-9102}"
BPORT="${BPORT:-9103}"

for tool in wrk curl elixir rebar3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "Compiling bench profile..."
rebar3 as bench compile >/dev/null
# App ebins (deps + livery) come from ERL_LIBS; the bench modules
# (livery_bench, bench_cowboy_h) compile to livery/bench, added with -pa.
BENCH_LIBS="$PWD/_build/bench/lib"
BENCH_PA="$BENCH_LIBS/livery/bench"

wait_ready() { # port
    for _ in $(seq 1 100); do
        curl -fsS "http://127.0.0.1:$1/" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

drive() { # label port
    echo
    echo "=== $1 (http/1.1, ${THREADS}t/${CONN}c/${DUR}s) ==="
    wrk -t"$THREADS" -c"$CONN" -d"${DUR}s" --latency "http://127.0.0.1:$2/"
}

bench_beam() { # label server port
    ERL_LIBS="$BENCH_LIBS" erl -noshell -pa "$BENCH_PA" \
        -eval "livery_bench:serve($2, h1, $3)" >/dev/null 2>&1 &
    local pid=$!
    if wait_ready "$3"; then drive "$1" "$3"; else echo "$1 did not become ready" >&2; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

bench_bandit() { # port
    elixir bench/servers/bandit_server.exs "$1" >/dev/null 2>&1 &
    local pid=$!
    if wait_ready "$1"; then drive "bandit" "$1"; else echo "bandit did not become ready (first run needs network for Mix.install)" >&2; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

bench_beam "livery" livery "$LPORT"
bench_beam "cowboy" cowboy "$CPORT"
bench_bandit "$BPORT"

echo
echo "Done. Note: livery serves H1 full bodies with chunked transfer-encoding;"
echo "cowboy and bandit send content-length. wrk handles both."
