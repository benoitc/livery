#!/usr/bin/env bash
#
# Fair cross-server benchmark: livery vs cowboy vs bandit, over HTTP/1.1
# (cleartext) and HTTP/2 (over TLS, ALPN-negotiated - the way h2 is
# actually deployed).
#
# Each server runs out of process on its own port and is driven by an
# external client (`wrk` for H1, `h2load` for H2), so all three are
# treated identically and the load generator never shares a VM with the
# server under test. Livery and cowboy boot under one BEAM (via
# livery_bench:serve/3); bandit boots under Elixir (Mix.install on first
# run, needs network). TLS uses the vendored self-signed test certs.
#
# Usage:
#   bench/compare.sh                 # 4 threads, 64 conns, 10s
#   DUR=20 CONN=128 THREADS=8 bench/compare.sh
#
# Requires: wrk, h2load, elixir, rebar3 (and curl).

set -euo pipefail
cd "$(dirname "$0")/.."

DUR="${DUR:-10}"
CONN="${CONN:-64}"
THREADS="${THREADS:-4}"
STREAMS="${STREAMS:-32}"   # h2 max concurrent streams per connection
CERT="$PWD/test/certs/cert.pem"
KEY="$PWD/test/certs/key.pem"

for tool in wrk h2load curl elixir rebar3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "Compiling bench profile..."
rebar3 as bench compile >/dev/null
# App ebins (deps + livery) come from ERL_LIBS; the bench modules
# (livery_bench, bench_cowboy_h) compile to livery/bench, added with -pa.
BENCH_LIBS="$PWD/_build/bench/lib"
BENCH_PA="$BENCH_LIBS/livery/bench"

# The server-side listener protocol for each benchmark mode.
serve_proto() { case "$1" in h1) echo h1 ;; h2) echo h2tls ;; esac; }

wait_ready() { # mode port
    local url
    case "$1" in h1) url="http://127.0.0.1:$2/" ;; h2) url="https://127.0.0.1:$2/" ;; esac
    for _ in $(seq 1 100); do
        curl -fskS "$url" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

drive() { # mode label port
    echo
    echo "=== $2 ($1, ${DUR}s) ==="
    case "$1" in
        h1) wrk -t"$THREADS" -c"$CONN" -d"${DUR}s" --latency "http://127.0.0.1:$3/" ;;
        h2) h2load -t"$THREADS" -c"$CONN" -m"$STREAMS" -D"$DUR" "https://127.0.0.1:$3/" \
                | grep -iE "Application protocol|finished|requests:|status codes" ;;
    esac
}

bench_beam() { # mode label server port
    ERL_LIBS="$BENCH_LIBS" erl -noshell -pa "$BENCH_PA" \
        -eval "livery_bench:serve($3, $(serve_proto "$1"), $4)" >/dev/null 2>&1 &
    local pid=$!
    if wait_ready "$1" "$4"; then drive "$1" "$2" "$4"; else echo "$2 did not become ready" >&2; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

bench_bandit() { # mode port
    case "$1" in
        h1) elixir bench/servers/bandit_server.exs "$2" >/dev/null 2>&1 & ;;
        h2) elixir bench/servers/bandit_server.exs "$2" "$CERT" "$KEY" >/dev/null 2>&1 & ;;
    esac
    local pid=$!
    if wait_ready "$1" "$2"; then drive "$1" "bandit" "$2"; else echo "bandit did not become ready (first run needs network for Mix.install)" >&2; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

echo
echo "##### HTTP/1.1 cleartext (wrk) #####"
bench_beam h1 "livery" livery 9101
bench_beam h1 "cowboy" cowboy 9102
bench_bandit h1 9103

echo
echo "##### HTTP/2 over TLS (h2load) #####"
bench_beam h2 "livery" livery 9111
bench_beam h2 "cowboy" cowboy 9112
bench_bandit h2 9113
