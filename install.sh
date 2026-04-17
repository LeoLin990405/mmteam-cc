#!/usr/bin/env bash
# install.sh — One-shot bootstrap for mmteam-cc.
#
# Phases:
#   0. Preflight       — detect OS, shell, writable PATH dirs
#   1. Deps check      — python3 ≥3.9 required; cmux/jq/7 launchers optional
#   2. Bin install      — copy bin/mmteam* to target dir
#   3. MCP register     — patch ~/.claude.json (backup first)
#   4. Smoke test       — mmteam --version + mcp self-check
#
# Flags:
#   --prefix <dir>     Override install dir (default: ~/.local/bin or ~/bin)
#   --no-dock          Set MMTEAM_NO_CMUX=1 in shell rc (disables cmux features)
#   --dry-run          Print what would happen without touching anything
#   --force            Overwrite existing bin files without prompt
#   --help             Show this message
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${CYAN}[info]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ok]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${NC}  %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC}  %s\n" "$*"; }
die()   { fail "$*"; exit 1; }

# ── Parse flags ──────────────────────────────────────────────────────────────

PREFIX=""
NO_DOCK=false
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix)   PREFIX="$2"; shift 2 ;;
    --no-dock)  NO_DOCK=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --force)    FORCE=true; shift ;;
    --help|-h)
      head -18 "$0" | tail -16
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

dry() { if $DRY_RUN; then info "[dry-run] $*"; return 0; fi; }

# ── Phase 0: Preflight ──────────────────────────────────────────────────────

echo ""
info "mmteam-cc installer"
info "root: ${ROOT}"
echo ""

OS="$(uname -s)"
ARCH="$(uname -m)"
info "OS: ${OS} / ${ARCH}"

if [[ -z "$PREFIX" ]]; then
  if [[ -d "$HOME/.local/bin" ]] && echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    PREFIX="$HOME/.local/bin"
  elif [[ -d "$HOME/bin" ]] && echo "$PATH" | tr ':' '\n' | grep -q "$HOME/bin"; then
    PREFIX="$HOME/bin"
  else
    PREFIX="$HOME/.local/bin"
    warn "~/.local/bin not in PATH — creating it; add to your shell rc:"
    warn '  export PATH="$HOME/.local/bin:$PATH"'
  fi
fi
info "install prefix: ${PREFIX}"

# ── Phase 1: Deps check ─────────────────────────────────────────────────────

echo ""
info "── Phase 1: dependency check ──"

ERRORS=0

# python3
if command -v python3 &>/dev/null; then
  PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  PY_MAJ=$(echo "$PY_VER" | cut -d. -f1)
  PY_MIN=$(echo "$PY_VER" | cut -d. -f2)
  if [[ $PY_MAJ -ge 3 ]] && [[ $PY_MIN -ge 9 ]]; then
    ok "python3 ${PY_VER}"
  else
    fail "python3 ${PY_VER} (need ≥3.9)"
    ERRORS=$((ERRORS+1))
  fi
else
  fail "python3 not found (required)"
  ERRORS=$((ERRORS+1))
fi

# node (for bridge scripts)
if command -v node &>/dev/null; then
  ok "node $(node -v)"
else
  fail "node not found (required for slash command bridge)"
  ERRORS=$((ERRORS+1))
fi

# Optional: cmux
if command -v cmux &>/dev/null; then
  ok "cmux (dock mode available)"
else
  warn "cmux not found (dock/watch features disabled — headless only)"
fi

# Optional: jq
if command -v jq &>/dev/null; then
  ok "jq (JSON processing available)"
else
  warn "jq not found (some output formatting degraded)"
fi

# Optional: 7 CC launchers
LAUNCHERS=(kimi-code glm-code doubao-code qwen-code minimax-code mimo-code stepfun-code)
FOUND_L=0
for l in "${LAUNCHERS[@]}"; do
  if command -v "$l" &>/dev/null; then
    FOUND_L=$((FOUND_L+1))
  fi
done
if [[ $FOUND_L -eq ${#LAUNCHERS[@]} ]]; then
  ok "all 7 CC launchers on PATH"
elif [[ $FOUND_L -gt 0 ]]; then
  warn "${FOUND_L}/${#LAUNCHERS[@]} CC launchers on PATH (missing ones won't be available as teammates)"
else
  warn "no CC launchers found — install cn-cc plugin or add them to PATH"
fi

# Optional: codex, gemini, claude
for extra in codex gemini claude; do
  if command -v "$extra" &>/dev/null; then
    ok "$extra"
  else
    warn "$extra not found (optional backend)"
  fi
done

if [[ $ERRORS -gt 0 ]]; then
  die "${ERRORS} required dep(s) missing — fix above and re-run."
fi

# ── Phase 2: Bin install ─────────────────────────────────────────────────────

echo ""
info "── Phase 2: install binaries ──"

BIN_FILES=(mmteam mmteam-a2a-server.py mmteam-a2a-monitor.py mmteam-mcp.py)

if $DRY_RUN; then
  for f in "${BIN_FILES[@]}"; do
    info "[dry-run] would copy ${ROOT}/bin/${f} → ${PREFIX}/${f}"
  done
else
  mkdir -p "$PREFIX"
  for f in "${BIN_FILES[@]}"; do
    SRC="${ROOT}/bin/${f}"
    DST="${PREFIX}/${f}"
    if [[ -f "$DST" ]] && ! $FORCE; then
      if cmp -s "$SRC" "$DST"; then
        ok "${f} (identical, skipped)"
        continue
      fi
      warn "${f} exists and differs — use --force to overwrite"
      continue
    fi
    cp "$SRC" "$DST"
    chmod +x "$DST"
    ok "${f} → ${DST}"
  done
fi

# ── Phase 3: MCP register ───────────────────────────────────────────────────

echo ""
info "── Phase 3: MCP registration ──"

MCP_SCRIPT="${PREFIX}/mmteam-mcp.py"

if $DRY_RUN; then
  info "[dry-run] would register mcpServers.mmteam → python3 ${MCP_SCRIPT}"
else
  if [[ -f "${ROOT}/plugins/mmteam/scripts/register-mcp.mjs" ]]; then
    node "${ROOT}/plugins/mmteam/scripts/register-mcp.mjs" "${MCP_SCRIPT}" || true
  else
    warn "register-mcp.mjs not found — manual MCP registration needed"
  fi
fi

# ── Phase 3b: --no-dock env ──────────────────────────────────────────────────

if $NO_DOCK; then
  info "Setting MMTEAM_NO_CMUX=1 ..."
  if $DRY_RUN; then
    info "[dry-run] would add 'export MMTEAM_NO_CMUX=1' to shell rc"
  else
    SHELL_RC=""
    if [[ -f "$HOME/.zshrc" ]]; then SHELL_RC="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then SHELL_RC="$HOME/.bashrc"
    fi
    if [[ -n "$SHELL_RC" ]]; then
      if ! grep -q 'MMTEAM_NO_CMUX' "$SHELL_RC" 2>/dev/null; then
        echo 'export MMTEAM_NO_CMUX=1  # mmteam: disable cmux dock features' >> "$SHELL_RC"
        ok "added to ${SHELL_RC}"
      else
        ok "already set in ${SHELL_RC}"
      fi
    else
      warn "no shell rc found — set MMTEAM_NO_CMUX=1 manually"
    fi
  fi
fi

# ── Phase 4: Smoke test ─────────────────────────────────────────────────────

echo ""
info "── Phase 4: smoke test ──"

if $DRY_RUN; then
  info "[dry-run] would verify mmteam --version and mmteam-mcp.py"
else
  if "${PREFIX}/mmteam" a2a --help &>/dev/null; then
    ok "mmteam a2a --help (binary works)"
  else
    warn "mmteam binary may not be fully functional — check PATH"
  fi

  if python3 -c "import sys; sys.path.insert(0,''); exec(open('${PREFIX}/mmteam-mcp.py').read().split('if __name__')[0])" 2>/dev/null; then
    ok "mmteam-mcp.py (parseable)"
  else
    warn "mmteam-mcp.py parse check failed — might be fine, verify after CC restart"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $DRY_RUN; then
  info "Dry run complete. Re-run without --dry-run to install."
else
  ok "Installation complete!"
  echo ""
  info "Next steps:"
  info "  1. Restart Claude Code to activate mcp__mmteam__a2a_* tools"
  info "  2. Run /mmteam:create <team> <specs...> to build your first team"
  info "  3. Run /mmteam:spawn <team> to start A2A daemons"
  info "  4. Run /mmteam:fanout <team> 'your question' for cross-model consensus"
  echo ""
  info "Troubleshooting: bash ${ROOT}/doctor.sh"
  info "Uninstall:       bash ${ROOT}/uninstall.sh"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
