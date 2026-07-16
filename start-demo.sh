#!/usr/bin/env bash
# Healthcare Radiology Edge Demo -- One-Command Startup
#
# Launches all 5 components in order, waits for health checks, prints
# connection info when ready. Press Ctrl-C to stop all services.
#
# Components:
#   1. MinIO          :9000 (API), :9001 (console)
#   2. S3 MCP Server  :3001
#   3. CV MCP Server  :3002
#   4. MCP Gateway    :8080 (broker), :50051 (router)
#   5. Envoy          :8888 (client-facing proxy)
#
# Prerequisites:
#   - MinIO installed (brew install minio/stable/minio)
#   - Envoy installed (brew install envoy)
#   - MCP Gateway binary built at ../mcp-gateway/bin/mcp-broker-router
#   - Python venvs created: servers/s3/.venv, servers/cv/.venv
#   - .env at repo root with GATEWAY_SIGNING_KEY and MinIO credentials

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# --- Load environment ---
if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found." >&2
  echo "Create it with at minimum: GATEWAY_SIGNING_KEY=<hex>" >&2
  exit 1
fi
set -a
source "$REPO_ROOT/.env"
set +a

# --- Track background PIDs for cleanup ---
PIDS=()

cleanup() {
  echo ""
  echo "Stopping demo services..."
  if [ ${#PIDS[@]} -gt 0 ]; then
    for pid in "${PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${PIDS[@]}"; do
      kill -9 "$pid" 2>/dev/null || true
    done
  fi
  echo "Demo stopped."
}
trap cleanup EXIT

# --- Port conflict check ---
check_port() {
  local port="$1"
  local service="$2"
  if lsof -i ":$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: Port $port is already in use (needed by $service)." >&2
    echo "Stop the existing process or free the port before starting the demo." >&2
    exit 1
  fi
}

echo "Checking for port conflicts..."
MINIO_ALREADY_RUNNING=false
if lsof -i ":9000" -sTCP:LISTEN >/dev/null 2>&1; then
  if curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1; then
    echo "  MinIO already running on :9000 -- will skip starting it."
    MINIO_ALREADY_RUNNING=true
  else
    echo "ERROR: Port 9000 is in use by something other than MinIO." >&2
    exit 1
  fi
fi
if [ "$MINIO_ALREADY_RUNNING" = "false" ]; then
  check_port 9001 "MinIO Console"
fi
check_port 3001 "S3 MCP Server"
check_port 3002 "CV MCP Server"
check_port 8080 "Gateway Broker"
check_port 8888 "Envoy Proxy"
echo "  All ports available."
echo ""

# --- Health wait function ---
wait_for_health() {
  local url="$1"
  local service="$2"
  local max_wait="${3:-30}"
  local elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "  $service ready."
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "ERROR: $service failed to start within ${max_wait}s." >&2
  echo "  Check log at /tmp/${service// /-}-demo.log" >&2
  exit 1
}

# --- Wait for port to accept connections (for Envoy which may not have a health endpoint) ---
wait_for_port() {
  local port="$1"
  local service="$2"
  local max_wait="${3:-30}"
  local elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    local http_code
    http_code=$(curl -so /dev/null -w "%{http_code}" "http://localhost:$port/" 2>/dev/null || echo "000")
    if [ "$http_code" != "000" ]; then
      echo "  $service ready (HTTP $http_code on :$port)."
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "ERROR: $service failed to start within ${max_wait}s." >&2
  echo "  Check log at /tmp/${service// /-}-demo.log" >&2
  exit 1
}

# ============================================================
# 1. MinIO
# ============================================================
if [ "$MINIO_ALREADY_RUNNING" = "true" ]; then
  echo "=== MinIO already running ==="
else
  echo "=== Starting MinIO ==="
  minio server ~/minio-data --console-address ":9001" \
    >/tmp/minio-demo.log 2>&1 &
  PIDS+=($!)
  wait_for_health "http://localhost:9000/minio/health/live" "MinIO" 15
fi
echo ""

# ============================================================
# 2. Bootstrap sample data (bucket + images)
# ============================================================
echo "=== Ensuring sample data in MinIO ==="
if [ ! -f "$REPO_ROOT/servers/s3/.venv/bin/python" ]; then
  echo "ERROR: Python venv not found at servers/s3/.venv" >&2
  echo "Create it: cd servers/s3 && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
"$REPO_ROOT/servers/s3/.venv/bin/python" "$REPO_ROOT/servers/s3/setup_minio.py"
echo "  Sample data ready."
echo ""

# ============================================================
# 3. S3 MCP Server
# ============================================================
echo "=== Starting S3 MCP Server ==="
cd "$REPO_ROOT/servers/s3"
.venv/bin/python server.py \
  >/tmp/s3-mcp-demo.log 2>&1 &
PIDS+=($!)
cd "$REPO_ROOT"
wait_for_health "http://localhost:3001/health" "S3 MCP Server" 15
echo ""

# ============================================================
# 4. CV MCP Server
# ============================================================
echo "=== Starting CV MCP Server ==="
cd "$REPO_ROOT/servers/cv"
if [ ! -f ".venv/bin/python" ]; then
  echo "ERROR: Python venv not found at servers/cv/.venv" >&2
  echo "Create it: cd servers/cv && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi
.venv/bin/python server.py \
  >/tmp/cv-mcp-demo.log 2>&1 &
PIDS+=($!)
cd "$REPO_ROOT"
wait_for_health "http://localhost:3002/health" "CV MCP Server" 30
echo ""

# ============================================================
# 5. MCP Gateway (Broker + Router)
# ============================================================
echo "=== Starting MCP Gateway ==="
GATEWAY_BINARY="$REPO_ROOT/../mcp-gateway/bin/mcp-broker-router"
if [ ! -x "$GATEWAY_BINARY" ]; then
  echo "ERROR: Gateway binary not found at $GATEWAY_BINARY" >&2
  echo "Build it: cd ../mcp-gateway && go build -o bin/mcp-broker-router ./cmd/mcp-broker-router" >&2
  exit 1
fi

"$GATEWAY_BINARY" \
  --mcp-gateway-config="$REPO_ROOT/gateway/config.yaml" \
  --mcp-gateway-public-host=localhost \
  --mcp-gateway-private-host=localhost:8888 \
  --log-level=-4 \
  >/tmp/gateway-demo.log 2>&1 &
PIDS+=($!)
wait_for_health "http://localhost:8080/healthz" "Gateway" 15
echo ""

# ============================================================
# 6. Envoy Proxy
# ============================================================
echo "=== Starting Envoy Proxy ==="
if ! command -v envoy &>/dev/null; then
  echo "ERROR: envoy not found on PATH." >&2
  echo "Install with: brew install envoy" >&2
  exit 1
fi

envoy -c "$REPO_ROOT/gateway/envoy.yaml" \
  >/tmp/envoy-demo.log 2>&1 &
PIDS+=($!)
wait_for_port 8888 "Envoy" 15
echo ""

# ============================================================
# Ready!
# ============================================================
echo "========================================================"
echo "  Healthcare Radiology Edge Demo is READY"
echo "========================================================"
echo ""
echo "  Gateway endpoint:  http://localhost:8888/mcp"
echo "  MinIO console:     http://localhost:9001"
echo "  MCP Inspector:     npx @anthropic-ai/mcp-inspector"
echo ""
echo "  Run E2E test:      bash run-e2e.sh"
echo ""
echo "  Press Ctrl-C to stop all services"
echo "========================================================"
echo ""

# Keep the script running until Ctrl-C
wait "${PIDS[@]}" 2>/dev/null || true
