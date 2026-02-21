#!/bin/bash

# REST API Test Script
# Usage: ./test_api.sh

BASE_URL="http://localhost:8080"

echo "=== Livery REST API Test Script ==="
echo ""

# List users
echo "1. List users:"
curl -s "$BASE_URL/api/users" | jq .
echo ""

# List users with pagination
echo "2. List users (page 1, limit 1):"
curl -s "$BASE_URL/api/users?page=1&limit=1" | jq .
echo ""

# Get user 1
echo "3. Get user 1:"
curl -s "$BASE_URL/api/users/1" | jq .
echo ""

# Get user 2
echo "4. Get user 2:"
curl -s "$BASE_URL/api/users/2" | jq .
echo ""

# Get non-existent user
echo "5. Get non-existent user (404):"
curl -s "$BASE_URL/api/users/999" | jq .
echo ""

# Create user
echo "6. Create user:"
curl -s -X POST "$BASE_URL/api/users" \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie","email":"charlie@example.com"}' | jq .
echo ""

# Create user with validation error
echo "7. Create user with missing email (validation error):"
curl -s -X POST "$BASE_URL/api/users" \
  -H "Content-Type: application/json" \
  -d '{"name":"Dave"}' | jq .
echo ""

# Update user
echo "8. Update user 1:"
curl -s -X PUT "$BASE_URL/api/users/1" \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice Smith"}' | jq .
echo ""

# List users again to see changes
echo "9. List users after changes:"
curl -s "$BASE_URL/api/users" | jq .
echo ""

# Delete user 2
echo "10. Delete user 2:"
curl -s -X DELETE "$BASE_URL/api/users/2" -w "HTTP Status: %{http_code}\n"
echo ""

# Verify deletion
echo "11. Verify user 2 deleted (404):"
curl -s "$BASE_URL/api/users/2" | jq .
echo ""

echo "=== Tests Complete ==="
