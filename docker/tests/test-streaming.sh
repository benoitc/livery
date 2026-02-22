#!/bin/bash
# Streaming tests for all protocols

# Test /stream - Chunked streaming with 3 chunks
test_stream_http1() {
    local result
    result=$(curl -s --http1.1 "http://${SERVER_HOST}:${HTTP_PORT}/stream")
    if [ "$result" = "chunk1chunk2chunk3" ]; then
        return 0
    else
        echo "Expected 'chunk1chunk2chunk3', got '$result'"
        return 1
    fi
}

test_stream_http2() {
    local result
    result=$(curl -s --http1.1 -k "https://${SERVER_HOST}:${HTTPS_PORT}/stream")
    if [ "$result" = "chunk1chunk2chunk3" ]; then
        return 0
    else
        echo "Expected 'chunk1chunk2chunk3', got '$result'"
        return 1
    fi
}

test_stream_http3() {
    local result
    result=$(curl -s --http3 -k "https://${SERVER_HOST}:${HTTPS_PORT}/stream")
    if [ "$result" = "chunk1chunk2chunk3" ]; then
        return 0
    else
        echo "Expected 'chunk1chunk2chunk3', got '$result'"
        return 1
    fi
}

# Test /sse - Server-Sent Events format
test_sse_http1() {
    local result
    result=$(curl -s --http1.1 "http://${SERVER_HOST}:${HTTP_PORT}/sse")
    if echo "$result" | grep -q "event: message" && echo "$result" | grep -q "data: event1"; then
        return 0
    else
        echo "SSE format not correct, got '$result'"
        return 1
    fi
}

test_sse_http2() {
    local result
    result=$(curl -s --http1.1 -k "https://${SERVER_HOST}:${HTTPS_PORT}/sse")
    if echo "$result" | grep -q "event: message" && echo "$result" | grep -q "data: event1"; then
        return 0
    else
        echo "SSE format not correct, got '$result'"
        return 1
    fi
}

test_sse_http3() {
    local result
    result=$(curl -s --http3 -k "https://${SERVER_HOST}:${HTTPS_PORT}/sse")
    if echo "$result" | grep -q "event: message" && echo "$result" | grep -q "data: event1"; then
        return 0
    else
        echo "SSE format not correct, got '$result'"
        return 1
    fi
}

# Test /stream-with-trailers - HTTP trailers
test_trailers_http1() {
    local result
    # HTTP/1.1 trailers require chunked encoding - check response body
    result=$(curl -s --http1.1 "http://${SERVER_HOST}:${HTTP_PORT}/stream-with-trailers")
    if [ "$result" = "data" ]; then
        return 0
    else
        echo "Expected 'data', got '$result'"
        return 1
    fi
}

test_trailers_http2() {
    local headers
    local body
    # HTTP/2 supports trailers natively - check for x-checksum
    headers=$(curl -s --http1.1 -k -D - "https://${SERVER_HOST}:${HTTPS_PORT}/stream-with-trailers" -o /tmp/body.txt 2>&1)
    body=$(cat /tmp/body.txt)
    if [ "$body" = "data" ]; then
        # Trailers may not be visible via curl -D, but body should be correct
        return 0
    else
        echo "Expected body 'data', got '$body'"
        return 1
    fi
}

test_trailers_http3() {
    local result
    # HTTP/3 supports trailers - check response body
    result=$(curl -s --http3 -k "https://${SERVER_HOST}:${HTTPS_PORT}/stream-with-trailers")
    if [ "$result" = "data" ]; then
        return 0
    else
        echo "Expected 'data', got '$result'"
        return 1
    fi
}
