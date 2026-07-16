#!/usr/bin/env bash
# Healthcare Radiology Edge Demo -- End-to-End Flow Verification
#
# Executes the full 5-step radiology analysis workflow through Envoy on :8888:
#   1. Initialize MCP session
#   2. List aggregated tools
#   3. List images via s3_list_objects
#   4. Fetch image via s3_get_object
#   5. Analyze image via cv_analyze_image
#
# Reports pass/fail per step with timing.
# Proves INT-01 (5-step flow) and INT-03 (steps 3-5 under 10 seconds).
#
# Prerequisites: All services must be running. Start with: bash start-demo.sh

set -euo pipefail

ENVOY="http://localhost:8888"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_STEPS=5

# --- Utility: print step result ---
step_result() {
  local step_name="$1"
  local passed="$2"
  local elapsed_ms="$3"

  if [ "$passed" = "true" ]; then
    echo "  [PASS] $step_name (${elapsed_ms}ms)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] $step_name (${elapsed_ms}ms)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Utility: current time in milliseconds ---
now_ms() {
  python3 -c "import time; print(int(time.time() * 1000))"
}

echo "========================================================"
echo "  Healthcare Radiology Edge Demo -- E2E Verification"
echo "========================================================"
echo ""

# --- Prerequisite: check Envoy is reachable ---
HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "$ENVOY/mcp" -X GET 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
  echo "ERROR: Envoy not reachable on :8888." >&2
  echo "Start the demo first: bash start-demo.sh" >&2
  exit 1
fi
echo "Envoy reachable on :8888 (HTTP $HTTP_CODE)."
echo ""

# ============================================================
# Step 1: Initialize MCP session
# ============================================================
echo "=== Step 1: Initialize MCP session ==="
STEP_START=$(now_ms)

HEADERS_FILE=$(mktemp)
INIT_RESP=$(curl -s -D "$HEADERS_FILE" "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0"}}}')

echo "$INIT_RESP" | python3 -m json.tool 2>/dev/null || echo "$INIT_RESP"

SESSION_ID=$(grep -i "mcp-session-id" "$HEADERS_FILE" | tr -d '\r' | awk '{print $2}')
rm -f "$HEADERS_FILE"

STEP_END=$(now_ms)
STEP_ELAPSED=$((STEP_END - STEP_START))

if [ -n "$SESSION_ID" ]; then
  step_result "Initialize session" "true" "$STEP_ELAPSED"
  echo "  Session ID: $SESSION_ID"
else
  step_result "Initialize session" "false" "$STEP_ELAPSED"
  echo ""
  echo "FATAL: Cannot continue without a session ID." >&2
  echo "  Is the Gateway running on :8080? Is Envoy running on :8888?" >&2
  exit 1
fi
echo ""

# ============================================================
# Step 2: List tools
# ============================================================
echo "=== Step 2: List aggregated tools ==="
STEP_START=$(now_ms)

TOOLS_RESP=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')

echo "$TOOLS_RESP" | python3 -m json.tool 2>/dev/null || echo "$TOOLS_RESP"

STEP2_PASS="true"
if ! echo "$TOOLS_RESP" | grep -q '"result"'; then
  STEP2_PASS="false"
fi

# Verify all expected tools are present
EXPECTED_TOOLS="s3_list_objects s3_get_object cv_analyze_image"
for tool in $EXPECTED_TOOLS; do
  if echo "$TOOLS_RESP" | grep -q "$tool"; then
    echo "  FOUND: $tool"
  else
    echo "  MISSING: $tool"
    STEP2_PASS="false"
  fi
done

STEP_END=$(now_ms)
STEP_ELAPSED=$((STEP_END - STEP_START))
step_result "List tools (3 expected)" "$STEP2_PASS" "$STEP_ELAPSED"
echo ""

# ============================================================
# Performance measurement starts here (steps 3-5)
# ============================================================
FLOW_START=$(now_ms)

# ============================================================
# Step 3: List images (s3_list_objects)
# ============================================================
echo "=== Step 3: List images (s3_list_objects) ==="
STEP_START=$(now_ms)

LIST_RESP=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"s3_list_objects","arguments":{}}}')

echo "$LIST_RESP" | python3 -m json.tool 2>/dev/null || echo "$LIST_RESP"

STEP3_PASS="false"
IMAGE_KEY=""
if echo "$LIST_RESP" | grep -q '"result"'; then
  # Extract the first image key from the response
  IMAGE_KEY=$(echo "$LIST_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
content = r['result']['content'][0]['text']
data = json.loads(content)
print(data['objects'][0]['key'])
" 2>/dev/null || echo "")
  if [ -n "$IMAGE_KEY" ]; then
    STEP3_PASS="true"
    echo "  First image key: $IMAGE_KEY"
  fi
fi

STEP_END=$(now_ms)
STEP_ELAPSED=$((STEP_END - STEP_START))
step_result "List images (s3_list_objects)" "$STEP3_PASS" "$STEP_ELAPSED"

if [ -z "$IMAGE_KEY" ]; then
  echo ""
  echo "FATAL: No image key found. Cannot continue steps 4-5." >&2
  echo "  Is MinIO running with sample data? Run: bash start-demo.sh" >&2
  exit 1
fi
echo ""

# ============================================================
# Step 4: Fetch image (s3_get_object)
# ============================================================
echo "=== Step 4: Fetch image (s3_get_object) ==="
STEP_START=$(now_ms)

FETCH_RESP=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"s3_get_object\",\"arguments\":{\"key\":\"$IMAGE_KEY\"}}}")

# Print a truncated version (base64 data can be huge)
echo "$FETCH_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
# Truncate base64 data for display
try:
    content = r['result']['content'][0]['text']
    data = json.loads(content)
    b64_len = len(data.get('data_base64', ''))
    data['data_base64'] = data['data_base64'][:40] + '...[truncated]' if b64_len > 40 else data.get('data_base64', '')
    r['result']['content'][0]['text'] = json.dumps(data)
except Exception:
    pass
print(json.dumps(r, indent=2))
" 2>/dev/null || echo "$FETCH_RESP"

STEP4_PASS="false"
if echo "$FETCH_RESP" | grep -q '"result"' && echo "$FETCH_RESP" | grep -q 'data_base64'; then
  STEP4_PASS="true"
  # Extract data size for display
  DATA_SIZE=$(echo "$FETCH_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
content = r['result']['content'][0]['text']
data = json.loads(content)
print(len(data.get('data_base64', '')))
" 2>/dev/null || echo "unknown")
  echo "  Image: $IMAGE_KEY (base64 length: $DATA_SIZE)"
fi

STEP_END=$(now_ms)
STEP_ELAPSED=$((STEP_END - STEP_START))
step_result "Fetch image (s3_get_object)" "$STEP4_PASS" "$STEP_ELAPSED"
echo ""

# ============================================================
# Step 5: Analyze image (cv_analyze_image)
# ============================================================
echo "=== Step 5: Analyze image (cv_analyze_image) ==="
STEP_START=$(now_ms)

ANALYZE_RESP=$(curl -s "$ENVOY/mcp" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"cv_analyze_image\",\"arguments\":{\"key\":\"$IMAGE_KEY\"}}}")

echo "$ANALYZE_RESP" | python3 -m json.tool 2>/dev/null || echo "$ANALYZE_RESP"

STEP5_PASS="false"
if echo "$ANALYZE_RESP" | grep -q '"result"' && \
   echo "$ANALYZE_RESP" | grep -q 'detection_count' && \
   echo "$ANALYZE_RESP" | grep -q 'token_count'; then
  STEP5_PASS="true"
  # Extract metrics for display
  echo "$ANALYZE_RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
content = r['result']['content'][0]['text']
data = json.loads(content)
print(f\"  Detections: {data.get('detection_count', 'N/A')}\")
print(f\"  Token count: {data.get('token_count', 'N/A')}\")
print(f\"  Inference count: {data.get('inference_count', 'N/A')}\")
print(f\"  Latency: {data.get('latency_ms', 'N/A')}ms\")
" 2>/dev/null || true
fi

STEP_END=$(now_ms)
STEP_ELAPSED=$((STEP_END - STEP_START))
step_result "Analyze image (cv_analyze_image)" "$STEP5_PASS" "$STEP_ELAPSED"
echo ""

# ============================================================
# Performance measurement ends (steps 3-5)
# ============================================================
FLOW_END=$(now_ms)
FLOW_DURATION_MS=$((FLOW_END - FLOW_START))

PERF_PASS="true"
if [ "$FLOW_DURATION_MS" -gt 10000 ]; then
  PERF_PASS="false"
fi

# ============================================================
# Summary
# ============================================================
echo "========================================================"
echo "  E2E Flow Results"
echo "========================================================"
echo ""
echo "  Total steps:  $TOTAL_STEPS"
echo "  Passed:       $PASS_COUNT"
echo "  Failed:       $FAIL_COUNT"
echo ""
echo "  Steps 3-5 wall time: ${FLOW_DURATION_MS}ms"
if [ "$PERF_PASS" = "true" ]; then
  echo "  Performance (< 10s target): PASS"
else
  echo "  Performance (< 10s target): FAIL (exceeded 10000ms)"
fi
echo ""

if [ "$FAIL_COUNT" -eq 0 ] && [ "$PERF_PASS" = "true" ]; then
  echo "  END-TO-END FLOW: PASS"
  echo ""
  echo "  INT-01 (5-step flow):      VERIFIED"
  echo "  INT-03 (< 10s perf):       VERIFIED (${FLOW_DURATION_MS}ms)"
else
  echo "  END-TO-END FLOW: FAIL"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  $FAIL_COUNT step(s) failed -- review output above."
  fi
  if [ "$PERF_PASS" = "false" ]; then
    echo "  Performance target missed: ${FLOW_DURATION_MS}ms > 10000ms."
  fi
fi
echo "========================================================"

# Exit with failure if any step failed or performance missed
if [ "$FAIL_COUNT" -gt 0 ] || [ "$PERF_PASS" = "false" ]; then
  exit 1
fi
