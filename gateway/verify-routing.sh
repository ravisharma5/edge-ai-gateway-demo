#!/usr/bin/env bash
# Verify Envoy routes tools/call to the correct backend MCP server
# Tests the full routing path: Client -> Envoy :8888 -> ext_proc (Router :50051)
#   -> :authority rewrite -> virtual host match -> backend cluster
#
# Prerequisites: All components must be running in order:
#   1. MinIO (minio server ~/minio-data --console-address ":9001")
#   2. S3 MCP Server (cd servers/s3 && source .venv/bin/activate && python server.py)
#   3. CV MCP Server (cd servers/cv && source .venv/bin/activate && python server.py)
#   4. Gateway (bash gateway/start-gateway.sh)
#   5. Envoy (bash gateway/start-envoy.sh)

set -euo pipefail

ENVOY="http://localhost:8888"
PASS=true

echo "=== Envoy Routing Verification ==="
echo ""

# Step 1: Initialize MCP session through Envoy
echo "=== Step 1: Initialize MCP session through Envoy ==="
HEADERS_FILE=$(mktemp)
RESP=$(curl -s -D "$HEADERS_FILE" "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify-routing","version":"1.0"}}}')

echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

SESSION_ID=$(grep -i "mcp-session-id" "$HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
rm -f "$HEADERS_FILE"

if [ -z "$SESSION_ID" ]; then
  echo "  FAIL - No Mcp-Session-Id in response headers"
  echo "  Is Envoy running on :8888? Is the Gateway running?"
  rm -f "$HEADERS_FILE" 2>/dev/null
  exit 1
fi
echo "  OK - Session ID: $SESSION_ID"
echo ""

# Step 2: List tools through Envoy
echo "=== Step 2: List tools through Envoy ==="
TOOLS=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')

echo "$TOOLS" | python3 -m json.tool 2>/dev/null || echo "$TOOLS"

if echo "$TOOLS" | grep -q '"result"'; then
  echo "  OK - tools/list returned result"
else
  echo "  FAIL - tools/list did not return a result"
  PASS=false
fi

# Verify expected tools are present
for tool in s3_list_objects s3_get_object cv_analyze_image; do
  if echo "$TOOLS" | grep -q "$tool"; then
    echo "  FOUND: $tool"
  else
    echo "  MISSING: $tool"
    PASS=false
  fi
done
echo ""

# Step 3: Route s3_list_objects through Envoy
# This proves: Router parses body, strips s3_ prefix, rewrites :authority to s3.local,
# Envoy re-routes to s3_backend cluster on :3001
echo "=== Step 3: Route s3_list_objects through Envoy ==="
S3_RESP=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"s3_list_objects","arguments":{}}}')

echo "$S3_RESP" | python3 -m json.tool 2>/dev/null || echo "$S3_RESP"

if echo "$S3_RESP" | grep -q '"result"'; then
  echo "  OK - s3_list_objects routed correctly to S3 server"
else
  echo "  FAIL - s3_list_objects did not return a result"
  echo "  Check: Is the S3 MCP server running on :3001? Is MinIO running?"
  PASS=false
fi
echo ""

# Step 4: Route cv_analyze_image through Envoy
# This proves: Router parses body, strips cv_ prefix, rewrites :authority to cv.local,
# Envoy re-routes to cv_backend cluster on :3002
# Note: Even an error response from the CV server (e.g., invalid image) proves routing works
echo "=== Step 4: Route cv_analyze_image through Envoy ==="
CV_RESP=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"cv_analyze_image","arguments":{"image_data":"dGVzdA=="}}}')

echo "$CV_RESP" | python3 -m json.tool 2>/dev/null || echo "$CV_RESP"

# Either "result" or "error" from the CV server means routing worked
# (an Envoy 500 or no response means routing failed)
if echo "$CV_RESP" | grep -q '"result"\|"error"'; then
  echo "  OK - cv_analyze_image routed to CV server"
else
  echo "  FAIL - cv_analyze_image not routed correctly"
  echo "  Check: Is the CV MCP server running on :3002?"
  PASS=false
fi
echo ""

# Summary
echo "==============================="
if [ "$PASS" = true ]; then
  echo "ALL STEPS PASSED"
  echo "Envoy routing is working correctly."
else
  echo "SOME STEPS FAILED"
  echo "Review the output above for details."
  exit 1
fi
