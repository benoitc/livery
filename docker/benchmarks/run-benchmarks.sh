#!/bin/bash
# Livery HTTP Server Benchmark Suite
# Tests HTTP/1.1, HTTP/2, and HTTP/3 performance

set -e

SERVER_HOST="${SERVER_HOST:-server}"
HTTP_PORT="${HTTP_PORT:-9080}"
HTTPS_PORT="${HTTPS_PORT:-9443}"

REQUESTS="${REQUESTS:-10000}"
CONCURRENCY="${CONCURRENCY:-100}"

echo "=============================================="
echo "      LIVERY HTTP SERVER BENCHMARK"
echo "=============================================="
echo ""
echo "Server: ${SERVER_HOST}"
echo "HTTP port: ${HTTP_PORT}, HTTPS port: ${HTTPS_PORT}"
echo "Requests: ${REQUESTS}, Concurrency: ${CONCURRENCY}"
echo ""

# Wait for server to be ready
echo "Waiting for server..."
for i in $(seq 1 30); do
    if curl -sf http://${SERVER_HOST}:${HTTP_PORT}/ > /dev/null 2>&1; then
        echo "Server ready!"
        break
    fi
    sleep 1
done

echo ""
echo "--- Verifying connectivity ---"
echo "HTTP/1.1: $(curl -s http://${SERVER_HOST}:${HTTP_PORT}/ || echo 'FAILED')"
echo "HTTPS/H2: $(curl -s -k https://${SERVER_HOST}:${HTTPS_PORT}/ || echo 'FAILED')"
echo "HTTP/3:   $(curl -s -k --http3-only https://${SERVER_HOST}:${HTTPS_PORT}/ 2>&1 || echo 'FAILED')"
echo ""

echo "=============================================="
echo "             BENCHMARK RESULTS"
echo "=============================================="

# HTTP/1.1 benchmark using h2load
echo ""
echo "--- HTTP/1.1 (h2load: ${REQUESTS} requests, ${CONCURRENCY} concurrent) ---"
H1_OUTPUT=$(h2load -n ${REQUESTS} -c ${CONCURRENCY} -p http/1.1 http://${SERVER_HOST}:${HTTP_PORT}/ 2>&1)
echo "$H1_OUTPUT"
H1_RPS=$(echo "$H1_OUTPUT" | grep "finished in" | awk '{print $4}')
H1_TIME=$(echo "$H1_OUTPUT" | grep "finished in" | awk '{print $3}' | sed 's/,//')

# HTTP/2 benchmark using h2load
echo ""
echo "--- HTTP/2 (h2load: ${REQUESTS} requests, ${CONCURRENCY} concurrent) ---"
H2_OUTPUT=$(h2load -n ${REQUESTS} -c ${CONCURRENCY} https://${SERVER_HOST}:${HTTPS_PORT}/ 2>&1)
echo "$H2_OUTPUT"
H2_RPS=$(echo "$H2_OUTPUT" | grep "finished in" | awk '{print $4}')
H2_TIME=$(echo "$H2_OUTPUT" | grep "finished in" | awk '{print $3}' | sed 's/,//')

# HTTP/3 benchmark using aioquic (single connection, multiplexed streams)
# Server now allows 1000 streams per connection
H3_REQUESTS=${H3_REQUESTS:-1000}
H3_CONCURRENCY=${H3_CONCURRENCY:-50}
echo ""
echo "--- HTTP/3 (aioquic: ${H3_REQUESTS} requests, ${H3_CONCURRENCY} concurrent) ---"
H3_OUTPUT=$(python3 /bench/h3bench.py -n ${H3_REQUESTS} -c ${H3_CONCURRENCY} -k https://${SERVER_HOST}:${HTTPS_PORT}/ 2>&1) || true
echo "$H3_OUTPUT"
H3_RPS=$(echo "$H3_OUTPUT" | grep "req/s           :" | awk '{print $3}')
H3_TIME=$(echo "$H3_OUTPUT" | grep "finished in" | awk '{print $3}' | sed 's/s,//')

echo ""
echo "=============================================="
echo "             SUMMARY"
echo "=============================================="
echo ""
printf "%-12s %15s %15s\n" "Protocol" "Time" "Requests/sec"
printf "%-12s %15s %15s\n" "--------" "----" "------------"
printf "%-12s %15s %15s\n" "HTTP/1.1" "${H1_TIME:-N/A}" "${H1_RPS:-N/A}"
printf "%-12s %15s %15s\n" "HTTP/2" "${H2_TIME:-N/A}" "${H2_RPS:-N/A}"
printf "%-12s %15s %15s\n" "HTTP/3" "${H3_TIME:-N/A}s" "${H3_RPS:-N/A}"
echo ""
# Note about H3 benchmark
if echo "$H3_OUTPUT" | grep -q "curl --http3-only"; then
    echo "Note: HTTP/3 used curl fallback (new connection per request)"
else
    echo "Note: H3 uses 1 QUIC connection with multiplexed streams"
    echo "      H1/H2 use 100 TCP connections"
fi
echo "=============================================="
