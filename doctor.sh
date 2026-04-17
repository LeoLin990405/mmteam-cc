#!/usr/bin/env bash
# doctor.sh — Diagnose mmteam-cc installation health.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { printf "  ${GREEN}✓${NC}  %-30s %s\n" "$1" "$2"; }
warn() { printf "  ${YELLOW}⚠${NC}  %-30s %s\n" "$1" "$2"; }
fail() { printf "  ${RED}✗${NC}  %-30s %s\n" "$1" "$2"; }

echo ""
printf "${CYAN}mmteam-cc doctor${NC}\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Required ─────────────────────────────────────────

printf "${CYAN}Required:${NC}\n"

if command -v python3 &>/dev/null; then
  ok "python3" "$(python3 --version 2>&1)"
else
  fail "python3" "not found"
fi

if command -v node &>/dev/null; then
  ok "node" "$(node -v)"
else
  fail "node" "not found"
fi

if command -v mmteam &>/dev/null; then
  ok "mmteam" "$(command -v mmteam)"
else
  fail "mmteam" "not on PATH — run install.sh"
fi

if command -v mmteam-mcp.py &>/dev/null || [[ -f "$HOME/.local/bin/mmteam-mcp.py" ]] || [[ -f "$HOME/bin/mmteam-mcp.py" ]]; then
  ok "mmteam-mcp.py" "found"
else
  fail "mmteam-mcp.py" "not found — run install.sh"
fi

# ── MCP Registration ─────────────────────────────────

echo ""
printf "${CYAN}MCP Registration:${NC}\n"

CLAUDE_JSON="$HOME/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  if command -v jq &>/dev/null; then
    MCP_ENTRY=$(jq -r '.mcpServers.mmteam.args[0] // empty' "$CLAUDE_JSON" 2>/dev/null)
    if [[ -n "$MCP_ENTRY" ]]; then
      ok "mcpServers.mmteam" "$MCP_ENTRY"
    else
      fail "mcpServers.mmteam" "not registered"
    fi
  else
    if grep -q '"mmteam"' "$CLAUDE_JSON" 2>/dev/null; then
      ok "mcpServers.mmteam" "(jq unavailable, but key found in file)"
    else
      fail "mcpServers.mmteam" "not registered (install jq for details)"
    fi
  fi
else
  fail "~/.claude.json" "not found"
fi

# ── Optional: cmux ───────────────────────────────────

echo ""
printf "${CYAN}Optional (dock features):${NC}\n"

if command -v cmux &>/dev/null; then
  ok "cmux" "$(cmux --version 2>&1 | head -1)"
else
  warn "cmux" "not found — dock/watch disabled, headless works fine"
fi

if command -v jq &>/dev/null; then
  ok "jq" "$(jq --version 2>&1)"
else
  warn "jq" "not found — some JSON features degraded"
fi

# ── CC Launchers ─────────────────────────────────────

echo ""
printf "${CYAN}CC Launchers (teammate backends):${NC}\n"

LAUNCHERS=(kimi-code glm-code doubao-code qwen-code minimax-code mimo-code stepfun-code codex gemini claude)
for l in "${LAUNCHERS[@]}"; do
  if command -v "$l" &>/dev/null; then
    ok "$l" "$(command -v "$l")"
  else
    warn "$l" "not found"
  fi
done

# ── Active teams ─────────────────────────────────────

echo ""
printf "${CYAN}Active teams:${NC}\n"

TEAMS_DIR="$HOME/.claude/teams"
if [[ -d "$TEAMS_DIR" ]]; then
  TEAM_COUNT=$(ls -d "$TEAMS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$TEAM_COUNT" -gt 0 ]]; then
    for td in "$TEAMS_DIR"/*/; do
      TNAME=$(basename "$td")
      DAEMON_COUNT=$(ls "$td"/*.a2a.pid 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$DAEMON_COUNT" -gt 0 ]]; then
        ok "$TNAME" "${DAEMON_COUNT} daemon PID file(s)"
      else
        warn "$TNAME" "no running daemons"
      fi
    done
  else
    warn "(none)" "no teams created yet"
  fi
else
  warn "~/.claude/teams/" "directory not found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
