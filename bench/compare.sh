#!/usr/bin/env bash
#
# Cross-server benchmark: livery vs cowboy vs bandit, over HTTP/1.1
# (cleartext, wrk) and HTTP/2 (over TLS, h2load), across a few realistic
# workloads:
#
#   tiny       GET  /            tiny JSON response
#   bytes1k    GET  /bytes/1024  1 KiB body
#   bytes10k   GET  /bytes/10240 10 KiB body
#   bytes100k  GET  /bytes/102400  100 KiB body
#   echo       POST /echo        decode + echo a small JSON body
#
# Each server runs out of process on its own port; an external client
# drives it, so all three are treated identically and the load generator
# never shares a VM with the server. Livery and cowboy boot under one BEAM
# (livery_bench:serve/3); bandit boots under Elixir (Mix.install on first
# run, needs network). H3 is livery only (cowboy/bandit have no HTTP/3, and
# external h3 load tools do not interoperate with the QUIC listener), so it
# is reported separately via livery's in-VM quic_h3 driver.
#
# Usage:
#   bench/compare.sh                       # full matrix, 4t/64c/10s
#   DUR=20 CONN=128 bench/compare.sh
#   SWEEP=1 bench/compare.sh               # also run a concurrency sweep
#
# Requires: wrk, h2load, elixir, rebar3, curl.

set -euo pipefail
cd "$(dirname "$0")/.."

DUR="${DUR:-10}"
CONN="${CONN:-64}"
THREADS="${THREADS:-4}"
STREAMS="${STREAMS:-32}"
SWEEP="${SWEEP:-0}"
CERT="$PWD/test/certs/cert.pem"
KEY="$PWD/test/certs/key.pem"

# name:method:path for each workload. echo carries a JSON body.
WORKLOADS=(
    "tiny:GET:/"
    "bytes1k:GET:/bytes/1024"
    "bytes10k:GET:/bytes/10240"
    "bytes100k:GET:/bytes/102400"
    "echo:POST:/echo"
)
ECHO_BODY='{"name":"ada","tags":["one","two","three"],"n":42,"ok":true}'

for tool in wrk h2load curl elixir rebar3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "Compiling bench profile..."
rebar3 as bench compile >/dev/null
BENCH_LIBS="$PWD/_build/bench/lib"
BENCH_PA="$BENCH_LIBS/livery/bench"

TMP="$(mktemp -d)"
RESULTS="$TMP/results"
: >"$RESULTS"
printf '%s' "$ECHO_BODY" >"$TMP/body.json"
cat >"$TMP/post.lua" <<LUA
wrk.method = "POST"
wrk.body   = [[$ECHO_BODY]]
wrk.headers["Content-Type"] = "application/json"
LUA

cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
SERVER_PID=""

serve_proto() { case "$1" in h1) echo h1 ;; h2) echo h2tls ;; esac; }

wait_ready() { # mode port
    local url
    case "$1" in h1) url="http://127.0.0.1:$2/" ;; h2) url="https://127.0.0.1:$2/" ;; esac
    for _ in $(seq 1 100); do curl -fskS "$url" >/dev/null 2>&1 && return 0; sleep 0.2; done
    return 1
}

# Run one workload and echo "req/s" (a bare number), printing the raw line.
drive_rps() { # mode port method path conns
    local mode="$1" port="$2" method="$3" path="$4" conns="$5" out rps
    if [ "$mode" = h1 ]; then
        if [ "$method" = POST ]; then
            out=$(wrk -t"$THREADS" -c"$conns" -d"${DUR}s" -s "$TMP/post.lua" "http://127.0.0.1:$port$path" 2>&1)
        else
            out=$(wrk -t"$THREADS" -c"$conns" -d"${DUR}s" "http://127.0.0.1:$port$path" 2>&1)
        fi
        rps=$(printf '%s\n' "$out" | grep -oE 'Requests/sec: *[0-9.]+' | grep -oE '[0-9.]+$' | head -1)
    else
        if [ "$method" = POST ]; then
            out=$(h2load -t"$THREADS" -c"$conns" -m"$STREAMS" -D"$DUR" -d "$TMP/body.json" "https://127.0.0.1:$port$path" 2>&1)
        else
            out=$(h2load -t"$THREADS" -c"$conns" -m"$STREAMS" -D"$DUR" "https://127.0.0.1:$port$path" 2>&1)
        fi
        rps=$(printf '%s\n' "$out" | grep -oE '[0-9.]+ req/s' | grep -oE '^[0-9.]+' | head -1)
    fi
    echo "${rps:-0}"
}

start_server() { # mode server port
    case "$2" in
        bandit)
            case "$1" in
                h1) elixir bench/servers/bandit_server.exs "$3" >/dev/null 2>&1 & ;;
                h2) elixir bench/servers/bandit_server.exs "$3" "$CERT" "$KEY" >/dev/null 2>&1 & ;;
            esac ;;
        *)
            ERL_LIBS="$BENCH_LIBS" erl -noshell -pa "$BENCH_PA" \
                -eval "livery_bench:serve($2, $(serve_proto "$1"), $3)" >/dev/null 2>&1 & ;;
    esac
    SERVER_PID=$!
}

stop_server() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }

run_matrix() { # mode servers...
    local mode="$1"; shift
    local base=9100; [ "$mode" = h2 ] && base=9110
    local i=0 server port wl name method path rps
    for server in "$@"; do
        port=$((base + i)); i=$((i + 1))
        start_server "$mode" "$server" "$port"
        if ! wait_ready "$mode" "$port"; then echo "$server ($mode) not ready" >&2; stop_server; continue; fi
        for wl in "${WORKLOADS[@]}"; do
            name="${wl%%:*}"; method="$(echo "$wl" | cut -d: -f2)"; path="${wl##*:}"
            rps=$(drive_rps "$mode" "$port" "$method" "$path" "$CONN")
            printf '%-8s %-10s %-10s %12s req/s\n' "$mode" "$server" "$name" "$rps"
            echo "$mode $server $name $rps" >>"$RESULTS"
        done
        stop_server
    done
}

echo
echo "##### HTTP/1.1 cleartext (wrk), ${THREADS}t/${CONN}c/${DUR}s #####"
run_matrix h1 livery cowboy bandit
echo
echo "##### HTTP/2 over TLS (h2load, ${STREAMS} streams/conn) #####"
run_matrix h2 livery cowboy bandit

echo
echo "##### HTTP/3 (livery only, in-VM quic_h3) #####"
echo "=== livery (h3, ${DUR}s) ==="
ERL_LIBS="$BENCH_LIBS" erl -noshell -pa "$BENCH_PA" \
    -eval "livery_bench:run(#{protocol => h3, connections => $CONN, duration_ms => $((DUR * 1000)), warmup_ms => 500})" \
    -eval "halt()" 2>/dev/null | grep -E "throughput|latency p50|latency p99"

if [ "$SWEEP" = 1 ]; then
    echo
    echo "##### Concurrency sweep (tiny GET, HTTP/1.1, wrk) #####"
    for server in livery cowboy bandit; do
        start_server h1 "$server" 9140
        if wait_ready h1 9140; then
            for c in 16 64 256 1024; do
                rps=$(drive_rps h1 9140 GET / "$c")
                printf '%-8s c=%-5s %12s req/s\n' "$server" "$c" "$rps"
            done
        fi
        stop_server
    done
fi

# Summary tables, one per protocol: rows = servers, columns = workloads.
echo
echo "##### Summary (req/s) #####"
awk '
{ rps[$1","$2","$3]=$4; servers[$2]=1; wl[$3]=1; modes[$1]=1 }
END {
    norder="tiny bytes1k bytes10k bytes100k echo"; nw=split(norder, W, " ")
    sorder="livery cowboy bandit"; ns=split(sorder, S, " ")
    morder="h1 h2"; nm=split(morder, M, " ")
    for (mi=1; mi<=nm; mi++) {
        m=M[mi]; if (!(m in modes)) continue
        printf "\n[%s]\n", (m=="h1" ? "HTTP/1.1" : "HTTP/2 over TLS")
        printf "%-9s", "server"
        for (wi=1; wi<=nw; wi++) printf "%12s", W[wi]
        printf "\n"
        for (si=1; si<=ns; si++) {
            s=S[si]; printf "%-9s", s
            for (wi=1; wi<=nw; wi++) { k=m","s","W[wi]; printf "%12s", (k in rps ? rps[k] : "-") }
            printf "\n"
        }
    }
}' "$RESULTS"
