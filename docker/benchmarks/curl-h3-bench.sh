#!/bin/bash
# HTTP/3 benchmark using curl parallel mode
# Usage: curl-h3-bench.sh [requests] [concurrency]

REQUESTS="${1:-1000}"
CONCURRENCY="${2:-50}"
SERVER_HOST="${SERVER_HOST:-server}"
HTTPS_PORT="${HTTPS_PORT:-9443}"

echo "HTTP/3 benchmark via curl: ${REQUESTS} requests, ${CONCURRENCY} parallel"

# Generate URL list
URL_FILE=$(mktemp)
for i in $(seq 1 ${REQUESTS}); do
    echo "url = https://${SERVER_HOST}:${HTTPS_PORT}/"
done > "${URL_FILE}"

# Run benchmark
START=$(date +%s.%N)
SUCCESS=$(curl --parallel --parallel-max ${CONCURRENCY} --http3-only -k -s -w "%{http_code}\n" -o /dev/null -K "${URL_FILE}" 2>&1 | grep -c "200" || echo "0")
END=$(date +%s.%N)

# Calculate stats
DURATION=$(echo "$END - $START" | bc)
RPS=$(echo "scale=2; ${REQUESTS} / ${DURATION}" | bc)
SUCCESS_RATE=$(echo "scale=2; ${SUCCESS} * 100 / ${REQUESTS}" | bc)

echo ""
echo "Results:"
echo "  Duration: ${DURATION}s"
echo "  Total requests: ${REQUESTS}"
echo "  Successful: ${SUCCESS}"
echo "  Success rate: ${SUCCESS_RATE}%"
echo "  Requests/sec: ${RPS}"

rm -f "${URL_FILE}"
