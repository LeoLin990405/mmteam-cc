#!/usr/bin/env bash
# Smoke test: verify register-mcp.mjs can register and remove.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/plugins/mmteam/scripts/register-mcp.mjs"
FAKE_MCP="/tmp/fake-mmteam-mcp-$$.py"

cleanup() { rm -f "$FAKE_MCP"; }
trap cleanup EXIT

# Create a fake script to register
echo '#!/usr/bin/env python3' > "$FAKE_MCP"
echo 'print("hello")' >> "$FAKE_MCP"

echo "=== smoke: register ==="
node "$SCRIPT" "$FAKE_MCP" || true  # exit 2 = already registered is OK

echo "=== smoke: status ==="
node "$SCRIPT" --status
echo "PASS: status reports registration"

echo "=== smoke: remove ==="
node "$SCRIPT" --remove
echo "PASS: removed"

echo "=== smoke: verify removal ==="
node "$SCRIPT" --status && {
  echo "FAIL: still registered after remove"
  exit 1
} || {
  echo "PASS: confirmed not registered"
}

# Re-register the real one if it was there before
if [[ -f "$HOME/.local/bin/mmteam-mcp.py" ]]; then
  node "$SCRIPT" "$HOME/.local/bin/mmteam-mcp.py" || true
elif [[ -f "$HOME/bin/mmteam-mcp.py" ]]; then
  node "$SCRIPT" "$HOME/bin/mmteam-mcp.py" || true
fi

echo ""
echo "ALL MCP REGISTER SMOKE TESTS PASSED"
