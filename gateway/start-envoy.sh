#!/usr/bin/env bash
# Start Envoy proxy for MCP Gateway routing
# Envoy sits in front of the Broker and Router, routing tools/call requests
# to the correct backend MCP server via ext_proc :authority rewriting.
#
# Prerequisites:
#   - envoy installed (brew install envoy)
#   - Gateway running (Broker :8080, Router :50051) -- start with: bash gateway/start-gateway.sh
#   - MCP servers running (S3 :3001, CV :3002)
#
# Ports:
#   - Envoy: :8888 (client-facing proxy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Verify Envoy is installed
if ! command -v envoy &>/dev/null; then
  echo "ERROR: envoy not found on PATH." >&2
  echo "Install with: brew install envoy" >&2
  exit 1
fi

# Verify config file exists
if [ ! -f "$SCRIPT_DIR/envoy.yaml" ]; then
  echo "ERROR: $SCRIPT_DIR/envoy.yaml not found." >&2
  echo "Expected Envoy config at gateway/envoy.yaml" >&2
  exit 1
fi

echo "Starting Envoy proxy..."
echo "  Config:   $SCRIPT_DIR/envoy.yaml"
echo "  Listener: http://localhost:8888"
echo "  ext_proc: Router on :50051"

exec envoy -c "$SCRIPT_DIR/envoy.yaml"
