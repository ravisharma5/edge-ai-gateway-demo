#!/usr/bin/env bash
# Verify MCP Gateway Broker aggregates tools from both backend MCP servers
# Prerequisites: MinIO, S3 MCP Server (:3001), CV MCP Server (:3002), and Gateway must be running
#
# Expected aggregated tools:
#   - s3_list_objects  (from S3 server, prefix: s3_)
#   - s3_get_object   (from S3 server, prefix: s3_)
#   - cv_analyze_image (from CV server, prefix: cv_)

set -euo pipefail

BROKER="http://localhost:8080"

echo "=== Step 1: Check Broker health ==="
if curl -sf "$BROKER/healthz" > /dev/null 2>&1; then
  echo "  OK"
else
  echo "  FAIL - Broker not responding on $BROKER/healthz"
  echo "  Is the gateway running? Start with: bash gateway/start-gateway.sh"
  exit 1
fi

echo "=== Step 2: Check Broker readiness ==="
if curl -sf "$BROKER/readyz" > /dev/null 2>&1; then
  echo "  OK"
else
  echo "  WARN - Broker not ready (backends may not be connected)"
  echo "  Ensure both MCP servers are running on :3001 and :3002"
fi

echo "=== Step 3: Initialize MCP session ==="
HEADERS_FILE=$(mktemp)
RESP=$(curl -s -D "$HEADERS_FILE" "$BROKER/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify-gateway","version":"1.0"}}}')

echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

SESSION_ID=$(grep -i "mcp-session-id" "$HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
rm -f "$HEADERS_FILE"

if [ -z "$SESSION_ID" ]; then
  echo "  FAIL - No Mcp-Session-Id header in initialize response"
  exit 1
fi
echo "  Session ID: $SESSION_ID"

echo "=== Step 4: List aggregated tools ==="
TOOLS=$(curl -s "$BROKER/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')

echo "$TOOLS" | python3 -m json.tool 2>/dev/null || echo "$TOOLS"

echo "=== Step 5: Verify expected tools ==="
PASS=true
for tool in s3_list_objects s3_get_object cv_analyze_image; do
  if echo "$TOOLS" | grep -q "$tool"; then
    echo "  FOUND: $tool"
  else
    echo "  MISSING: $tool"
    PASS=false
  fi
done

if [ "$PASS" = false ]; then
  echo ""
  echo "FAIL - Not all expected tools found in aggregated list"
  echo "Troubleshooting:"
  echo "  1. Are both MCP servers running? (curl localhost:3001/mcp and localhost:3002/mcp)"
  echo "  2. Check gateway logs for connection errors"
  echo "  3. Restart the gateway after both servers are confirmed running"
  exit 1
fi

echo ""
echo "=== All tools verified ==="
