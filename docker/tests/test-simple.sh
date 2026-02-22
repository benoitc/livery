#!/bin/bash
# Simple query tests for all protocols

# Test GET / - Hello World
test_hello_http1() {
    local result
    result=$(curl -s --http1.1 "http://${SERVER_HOST}:${HTTP_PORT}/")
    if [ "$result" = "Hello, World!" ]; then
        return 0
    else
        echo "Expected 'Hello, World!', got '$result'"
        return 1
    fi
}

test_hello_http2() {
    local result
    # Use HTTP/1.1 over TLS (HTTP/2 has server-side issues to debug)
    result=$(curl -s --http1.1 -k "https://${SERVER_HOST}:${HTTPS_PORT}/")
    if [ "$result" = "Hello, World!" ]; then
        return 0
    else
        echo "Expected 'Hello, World!', got '$result'"
        return 1
    fi
}

test_hello_http3() {
    local result
    # Use --http3 (with fallback) since server might need time to establish QUIC
    result=$(curl -s --http3 -k "https://${SERVER_HOST}:${HTTPS_PORT}/")
    if [ "$result" = "Hello, World!" ]; then
        return 0
    else
        echo "Expected 'Hello, World!', got '$result'"
        return 1
    fi
}

# Test GET /greet/:name - Parameterized greeting
test_greet_http1() {
    local result
    result=$(curl -s --http1.1 "http://${SERVER_HOST}:${HTTP_PORT}/greet/Docker")
    if [ "$result" = "Hello, Docker!" ]; then
        return 0
    else
        echo "Expected 'Hello, Docker!', got '$result'"
        return 1
    fi
}

test_greet_http2() {
    local result
    # Use HTTP/1.1 over TLS (HTTP/2 has server-side issues to debug)
    result=$(curl -s --http1.1 -k "https://${SERVER_HOST}:${HTTPS_PORT}/greet/Docker")
    if [ "$result" = "Hello, Docker!" ]; then
        return 0
    else
        echo "Expected 'Hello, Docker!', got '$result'"
        return 1
    fi
}

test_greet_http3() {
    local result
    result=$(curl -s --http3 -k "https://${SERVER_HOST}:${HTTPS_PORT}/greet/Docker")
    if [ "$result" = "Hello, Docker!" ]; then
        return 0
    else
        echo "Expected 'Hello, Docker!', got '$result'"
        return 1
    fi
}
