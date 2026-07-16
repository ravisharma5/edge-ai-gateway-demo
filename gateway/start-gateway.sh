#!/usr/bin/env bash
# Start MCP Gateway (Broker + Router) for Healthcare Radiology Edge Demo
# Source: Kuadrant/mcp-gateway binary install guide + main.go flag definitions
#
# Prerequisites:
#   - mcp-broker-router binary built at ../mcp-gateway/bin/mcp-broker-router
#   - .env at repo root with GATEWAY_SIGNING_KEY
#
# Ports:
#   - Broker: :8080 (MCP JSON-RPC, health, readiness)
#   - Router: :50051 (Envoy ext_proc gRPC, used in Phase 4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load shared env (MinIO creds + GATEWAY_SIGNING_KEY)
if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found. Create it with GATEWAY_SIGNING_KEY." >&2
  exit 1
fi
set -a
source "$REPO_ROOT/.env"
set +a

# Verify signing key is present (binary panics without it)
if [ -z "${GATEWAY_SIGNING_KEY:-}" ]; then
  echo "ERROR: GATEWAY_SIGNING_KEY not set in .env. Generate with: openssl rand -hex 32" >&2
  exit 1
fi

# Path to binary in sibling mcp-gateway repo (D-01)
BINARY="$REPO_ROOT/../mcp-gateway/bin/mcp-broker-router"
if [ ! -x "$BINARY" ]; then
  echo "ERROR: Binary not found at $BINARY" >&2
  echo "Build it: cd ../mcp-gateway && go build -o bin/mcp-broker-router ./cmd/mcp-broker-router" >&2
  exit 1
fi

echo "Starting MCP Gateway..."
echo "  Config: $SCRIPT_DIR/config.yaml"
echo "  Broker: http://localhost:8080"
echo "  Router: localhost:50051"

exec "$BINARY" \
  --mcp-gateway-config="$SCRIPT_DIR/config.yaml" \
  --mcp-gateway-public-host=localhost \
  --mcp-gateway-private-host=localhost:8888 \
  --log-level=-4
