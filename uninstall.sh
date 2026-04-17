#!/usr/bin/env bash
# uninstall.sh — Remove mmteam binaries and MCP registration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${CYAN}[info]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${NC}  %s\n" "$*"; }

echo ""
info "mmteam-cc uninstaller"
echo ""

BIN_FILES=(mmteam mmteam-a2a-server.py mmteam-a2a-monitor.py mmteam-mcp.py)
DIRS=("$HOME/.local/bin" "$HOME/bin" "/usr/local/bin")

for d in "${DIRS[@]}"; do
  for f in "${BIN_FILES[@]}"; do
    if [[ -f "${d}/${f}" ]]; then
      rm "${d}/${f}"
      ok "removed ${d}/${f}"
    fi
  done
done

# Remove MCP registration
if [[ -f "${ROOT}/plugins/mmteam/scripts/register-mcp.mjs" ]]; then
  node "${ROOT}/plugins/mmteam/scripts/register-mcp.mjs" --remove 2>/dev/null || true
fi

# Clean up MMTEAM_NO_CMUX from shell rc
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [[ -f "$rc" ]] && grep -q 'MMTEAM_NO_CMUX' "$rc"; then
    sed -i.bak '/MMTEAM_NO_CMUX/d' "$rc"
    ok "removed MMTEAM_NO_CMUX from ${rc}"
  fi
done

echo ""
ok "Uninstall complete. Restart Claude Code to remove mcp__mmteam__a2a_* tools."
info "Team data (~/.claude/teams/) is preserved. Delete manually if desired."
