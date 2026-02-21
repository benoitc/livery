#!/bin/bash

# WebSocket Test Script
# Usage: ./test_ws.sh
#
# Requirements:
# - websocat: brew install websocat (macOS) or cargo install websocat

echo "=== Livery WebSocket Test Script ==="
echo ""
echo "This script tests the WebSocket examples."
echo "Make sure the server is running on localhost:8080"
echo ""

# Check if websocat is installed
if ! command -v websocat &> /dev/null; then
    echo "websocat is not installed."
    echo "Install with: brew install websocat (macOS) or cargo install websocat"
    echo ""
    echo "Alternatively, test using curl to verify the HTTP endpoints:"
    echo ""
    echo "# Get index page"
    curl -s http://localhost:8080/ | head -20
    echo "..."
    echo ""
    echo "# Check echo endpoint (HTTP)"
    curl -s http://localhost:8080/echo
    echo ""
    echo ""
    echo "# Check chat endpoint (HTTP)"
    curl -s http://localhost:8080/chat
    echo ""
    exit 1
fi

echo "1. Testing Echo Server"
echo "   Sending 'Hello' to echo server..."
echo "Hello" | timeout 2 websocat ws://localhost:8080/echo
echo ""

echo "2. Testing Chat Server (interactive)"
echo "   Run this command in separate terminals to chat:"
echo ""
echo "   Terminal 1: websocat 'ws://localhost:8080/chat?username=alice'"
echo "   Terminal 2: websocat 'ws://localhost:8080/chat?username=bob'"
echo ""
echo "   Type messages in each terminal to see them broadcast."
echo ""

echo "3. Manual WebSocket upgrade test with curl:"
echo ""
echo "curl --include --no-buffer \\"
echo "  --header \"Connection: Upgrade\" \\"
echo "  --header \"Upgrade: websocket\" \\"
echo "  --header \"Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==\" \\"
echo "  --header \"Sec-WebSocket-Version: 13\" \\"
echo "  http://localhost:8080/echo"
echo ""

echo "=== End of Tests ==="
