#!/usr/bin/env bash
# Healthcare Radiology Edge Demo -- Setup Script
#
# Checks prerequisites, creates Python virtual environments, installs
# dependencies, and generates .env. Run once after cloning.
#
# Usage:
#   bash setup.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ERRORS=()

echo "========================================================"
echo "  Healthcare Radiology Edge Demo -- Setup"
echo "========================================================"
echo ""

# ============================================================
# 1. Check prerequisites
# ============================================================
echo "=== Checking prerequisites ==="

check_command() {
  local cmd="$1"
  local install_hint="$2"
  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>&1 | head -1)
    echo "  [OK] $cmd -- $version"
  else
    echo "  [MISSING] $cmd -- install with: $install_hint"
    ERRORS+=("$cmd not found")
  fi
}

# Python 3.12 preferred, but 3.10+ works
PYTHON_CMD=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" &>/dev/null; then
    py_version=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
    py_major=$(echo "$py_version" | cut -d. -f1)
    py_minor=$(echo "$py_version" | cut -d. -f2)
    if [ "$py_major" -ge 3 ] && [ "$py_minor" -ge 10 ]; then
      PYTHON_CMD="$candidate"
      echo "  [OK] python -- $("$candidate" --version 2>&1)"
      break
    fi
  fi
done
if [ -z "$PYTHON_CMD" ]; then
  echo "  [MISSING] python 3.10+ -- install with: brew install python@3.12"
  ERRORS+=("python 3.10+ not found")
fi

check_command "go" "brew install go"
check_command "envoy" "brew install envoy"

if command -v minio &>/dev/null; then
  echo "  [OK] minio"
else
  echo "  [MISSING] minio -- install with: brew install minio/stable/minio"
  ERRORS+=("minio not found")
fi

echo ""

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "ERROR: Missing prerequisites:"
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  echo ""
  echo "Install the missing tools above, then re-run: bash setup.sh"
  exit 1
fi

# ============================================================
# 2. Create .env from template if missing
# ============================================================
echo "=== Setting up .env ==="

if [ -f "$REPO_ROOT/.env" ]; then
  echo "  .env already exists -- skipping."
else
  cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
  SIGNING_KEY=$(openssl rand -hex 32)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/^GATEWAY_SIGNING_KEY=$/GATEWAY_SIGNING_KEY=$SIGNING_KEY/" "$REPO_ROOT/.env"
  else
    sed -i "s/^GATEWAY_SIGNING_KEY=$/GATEWAY_SIGNING_KEY=$SIGNING_KEY/" "$REPO_ROOT/.env"
  fi
  echo "  Created .env with generated GATEWAY_SIGNING_KEY."
fi
echo ""

# ============================================================
# 3. Create Python virtual environments and install deps
# ============================================================
echo "=== Setting up Python environments ==="

setup_venv() {
  local name="$1"
  local dir="$2"
  local req="$3"

  if [ -f "$dir/.venv/bin/python" ]; then
    echo "  [$name] venv exists -- reinstalling deps..."
  else
    echo "  [$name] Creating venv..."
    "$PYTHON_CMD" -m venv "$dir/.venv"
  fi
  "$dir/.venv/bin/pip" install --quiet --upgrade pip
  "$dir/.venv/bin/pip" install --quiet -r "$req"
  echo "  [$name] Ready."
}

setup_venv "S3 Server" "$REPO_ROOT/servers/s3" "$REPO_ROOT/servers/s3/requirements.txt"
setup_venv "CV Server" "$REPO_ROOT/servers/cv" "$REPO_ROOT/servers/cv/requirements.txt"
setup_venv "Demo App" "$REPO_ROOT/demo" "$REPO_ROOT/demo/requirements.txt"

echo ""

# ============================================================
# 4. Build MCP Gateway (if sibling repo exists)
# ============================================================
echo "=== MCP Gateway ==="

GATEWAY_REPO="$REPO_ROOT/../mcp-gateway"
GATEWAY_BINARY="$GATEWAY_REPO/bin/mcp-broker-router"

if [ -x "$GATEWAY_BINARY" ]; then
  echo "  Gateway binary already built."
elif [ -d "$GATEWAY_REPO" ]; then
  echo "  Building gateway from source..."
  (cd "$GATEWAY_REPO" && go build -o bin/mcp-broker-router ./cmd/mcp-broker-router)
  echo "  Gateway binary built."
else
  echo "  Gateway source not found at $GATEWAY_REPO"
  echo "  Clone it:"
  echo "    cd .. && git clone https://github.com/Kuadrant/mcp-gateway.git"
  echo "    cd mcp-gateway && go build -o bin/mcp-broker-router ./cmd/mcp-broker-router"
  echo ""
  echo "  (The demo won't start without this binary.)"
fi
echo ""

# ============================================================
# Done
# ============================================================
echo "========================================================"
echo "  Setup complete!"
echo "========================================================"
echo ""
echo "  Next steps:"
echo "    1. bash start-demo.sh        # Start all services"
echo "    2. demo/.venv/bin/streamlit run demo/app.py   # Launch UI"
echo "    3. bash run-e2e.sh            # Run E2E verification"
echo "========================================================"
