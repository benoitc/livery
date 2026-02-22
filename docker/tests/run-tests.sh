#!/bin/bash
# Main test orchestrator for Livery Docker test suite

# Don't use set -e as it causes issues with arithmetic operations returning 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test files
source "${SCRIPT_DIR}/test-simple.sh"
source "${SCRIPT_DIR}/test-streaming.sh"
source "${SCRIPT_DIR}/test-large-data.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SERVER_HOST="${SERVER_HOST:-server}"
HTTP_PORT="${HTTP_PORT:-9080}"
HTTPS_PORT="${HTTPS_PORT:-9443}"

# Check if HTTP/3 is supported
HTTP3_SUPPORTED=false
if curl --version | grep -qi "http3"; then
    HTTP3_SUPPORTED=true
fi

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Run a single test
run_test() {
    local protocol="$1"
    local test_name="$2"
    local test_func="$3"

    printf "  "
    if $test_func 2>/dev/null; then
        printf "${GREEN}✓${NC} %s\n" "$test_name"
        ((PASSED++))
    else
        printf "${RED}✗${NC} %s\n" "$test_name"
        ((FAILED++))
    fi
}

# Skip a test
skip_test() {
    local test_name="$1"
    printf "  ${YELLOW}⊘${NC} %s (skipped - HTTP/3 not available)\n" "$test_name"
    ((SKIPPED++))
}

# Wait for server to be ready
wait_for_server() {
    echo "Waiting for server to be ready..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://${SERVER_HOST}:${HTTP_PORT}/" > /dev/null 2>&1; then
            echo "Server is ready!"
            return 0
        fi
        ((attempt++))
        sleep 1
    done
    echo "Server failed to start"
    return 1
}

echo ""
echo -e "${BLUE}=== Livery Docker Test Suite ===${NC}"
echo ""

# Wait for server
wait_for_server

# Simple Query Tests
echo -e "${YELLOW}[HTTP/1.1] Simple Queries${NC}"
run_test "HTTP/1.1" "GET / returns \"Hello, World!\"" test_hello_http1
run_test "HTTP/1.1" "GET /greet/Docker returns \"Hello, Docker!\"" test_greet_http1
echo ""

echo -e "${YELLOW}[HTTPS] Simple Queries${NC}"
run_test "HTTP/2" "GET / returns \"Hello, World!\"" test_hello_http2
run_test "HTTP/2" "GET /greet/Docker returns \"Hello, Docker!\"" test_greet_http2
echo ""

echo -e "${YELLOW}[HTTP/3] Simple Queries${NC}"
if [ "$HTTP3_SUPPORTED" = true ]; then
    run_test "HTTP/3" "GET / returns \"Hello, World!\"" test_hello_http3
    run_test "HTTP/3" "GET /greet/Docker returns \"Hello, Docker!\"" test_greet_http3
else
    skip_test "GET / returns \"Hello, World!\""
    skip_test "GET /greet/Docker returns \"Hello, Docker!\""
fi
echo ""

# Streaming Tests
echo -e "${YELLOW}[HTTP/1.1] Streaming${NC}"
run_test "HTTP/1.1" "/stream returns 3 chunks" test_stream_http1
run_test "HTTP/1.1" "/sse returns SSE format" test_sse_http1
run_test "HTTP/1.1" "/stream-with-trailers works" test_trailers_http1
echo ""

echo -e "${YELLOW}[HTTPS] Streaming${NC}"
run_test "HTTP/2" "/stream returns 3 chunks" test_stream_http2
run_test "HTTP/2" "/sse returns SSE format" test_sse_http2
run_test "HTTP/2" "/stream-with-trailers works" test_trailers_http2
echo ""

echo -e "${YELLOW}[HTTP/3] Streaming${NC}"
if [ "$HTTP3_SUPPORTED" = true ]; then
    run_test "HTTP/3" "/stream returns 3 chunks" test_stream_http3
    run_test "HTTP/3" "/sse returns SSE format" test_sse_http3
    run_test "HTTP/3" "/stream-with-trailers works" test_trailers_http3
else
    skip_test "/stream returns 3 chunks"
    skip_test "/sse returns SSE format"
    skip_test "/stream-with-trailers works"
fi
echo ""

# Large Data Tests
echo -e "${YELLOW}[HTTP/1.1] Large Data${NC}"
run_test "HTTP/1.1" "/large returns 1MB" test_large_http1
echo ""

echo -e "${YELLOW}[HTTPS] Large Data${NC}"
run_test "HTTP/2" "/large returns 1MB" test_large_http2
echo ""

echo -e "${YELLOW}[HTTP/3] Large Data${NC}"
if [ "$HTTP3_SUPPORTED" = true ]; then
    run_test "HTTP/3" "/large returns 1MB" test_large_http3
else
    skip_test "/large returns 1MB"
fi
echo ""

# Summary
if [ $SKIPPED -gt 0 ]; then
    echo -e "${BLUE}=== Results: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}, ${YELLOW}${SKIPPED} skipped${NC} ===${NC}"
else
    echo -e "${BLUE}=== Results: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC} ===${NC}"
fi
echo ""

if [ $FAILED -gt 0 ]; then
    exit 1
fi

exit 0
