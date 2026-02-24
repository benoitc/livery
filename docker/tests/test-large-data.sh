#!/bin/bash
# Large data transfer tests for all protocols

EXPECTED_SIZE=1048576  # 1MB

# Test /large - 1MB response
test_large_http1() {
    local size
    size=$(curl -s --http1.1 "http://${SERVER_HOST}:${HTTP_PORT}/large" | wc -c)
    if [ "$size" -eq "$EXPECTED_SIZE" ]; then
        return 0
    else
        echo "Expected $EXPECTED_SIZE bytes, got $size bytes"
        return 1
    fi
}

test_large_http2() {
    local size
    size=$(curl -s --http1.1 -k "https://${SERVER_HOST}:${HTTPS_PORT}/large" | wc -c)
    if [ "$size" -eq "$EXPECTED_SIZE" ]; then
        return 0
    else
        echo "Expected $EXPECTED_SIZE bytes, got $size bytes"
        return 1
    fi
}

test_large_http3() {
    local size
    # Small delay to allow server to stabilize after previous requests
    sleep 0.3
    size=$(curl -s --http3 -k "https://${SERVER_HOST}:${HTTPS_PORT}/large" | wc -c)
    if [ "$size" -eq "$EXPECTED_SIZE" ]; then
        return 0
    else
        echo "Expected $EXPECTED_SIZE bytes, got $size bytes"
        return 1
    fi
}
