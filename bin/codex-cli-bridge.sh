#!/usr/bin/env bash
# codex-cli-bridge.sh — Drive `codex` CLI as a bridge surface (separate from Codex App).
#
# This wraps `codex exec` so Claude can drive the codex CLI as one of the 5
# surfaces. The CLI runs synchronously: process exit = completion signal.
#
# IMPORTANT: This uses your `codex` CLI quota (~/.npm-global/bin/codex), which
# is independent from the Codex Desktop App account. If you want the App's
# quota, use codex-bridge.sh (the App-driving variant) instead.
#
# Usage:
#   codex-cli-bridge.sh status
#   codex-cli-bridge.sh ask    <text>      [--timeout S] [--sandbox MODE]
#   codex-cli-bridge.sh review <prompt-file> [--timeout S] [--sandbox MODE]
#
# --sandbox MODE: read-only (default, safe) / workspace-write / danger-full-access
#                 review uses read-only by default — Claude patches NEEDS_FIX,
#                 not the CLI.
#
# review output (same shape as codex-bridge for unified Claude consumption):
#   VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
#   ISSUES_COUNT=N
#   RESPONSE_FILE=/tmp/codex-cli-bridge/...md
#   ---
#   <full markdown response>

set -euo pipefail

source "$HOME/.claude/bin/_bridge_route.sh"

CMD="${1:-}"
TIMEOUT_SEC=600
SANDBOX_MODE="read-only"
OUT_DIR="/tmp/codex-cli-bridge"
mkdir -p "$OUT_DIR"

die() { echo "[codex-cli-bridge] $*" >&2; exit "${2:-1}"; }

require_codex_cli() {
  if ! command -v codex >/dev/null 2>&1; then
    die "codex CLI not found in PATH. Install: npm i -g @openai/codex-cli (or check ~/.npm-global/bin/codex)" 1
  fi
}

extract_verdict() {
  local v
  v=$(grep -oiE 'VERDICT:\s*(ACCEPTED|NEEDS[ _-]?FIX)' "$1" 2>/dev/null | head -1 | awk -F: '{print $2}' | xargs | tr '[:lower:]' '[:upper:]' | tr ' ' '_')
  [ -z "$v" ] && v=$(grep -oE '^(ACCEPTED|NEEDS[ _-]?FIX)\b' "$1" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]' | tr ' ' '_')
  [ -z "$v" ] && v="UNKNOWN"
  echo "$v"
}

extract_issues_count() {
  awk '
    /^###?[[:space:]]*Issues[[:space:]]+found/i { in_issues=1; next }
    in_issues && /^###/ { exit }
    in_issues && /^[[:space:]]*[0-9]+\./ { c++ }
    END { print c+0 }
  ' "$1" 2>/dev/null
}

cmd_list() {
  CODEX_SESS_DIR="$HOME/.codex/sessions" python3 <<'PYEOF'
import json, os
d = os.environ.get("CODEX_SESS_DIR", "")
sessions = []
if os.path.isdir(d):
    try:
        names = sorted(
            os.listdir(d),
            key=lambda f: os.path.getmtime(os.path.join(d, f)),
            reverse=True
        )[:10]
        sessions = [{"id": n, "on_disk": True} for n in names]
    except Exception:
        pass
print(json.dumps({
    "surface": "codex-cli",
    "stateless": True,
    "active_session": None,
    "sessions": sessions,
    "note": "codex CLI is stateless per-invocation. --continue / --resume flags can attach to a prior session by id; otherwise each ask starts fresh."
}, indent=2))
PYEOF
}

cmd_modes() {
  CODEX_SANDBOX="$SANDBOX_MODE" python3 <<'PYEOF'
import json, os
print(json.dumps({
    "surface": "codex-cli",
    "axis": "sandbox",
    "active_mode": os.environ.get("CODEX_SANDBOX"),
    "available_modes": ["read-only", "workspace-write", "danger-full-access"],
    "note": "Codex CLI's mode axis is its sandbox permission level, not a chat mode."
}, indent=2))
PYEOF
}

cmd_status() {
  require_codex_cli
  echo "codex CLI: $(command -v codex)"
  echo "version: $(codex --version 2>&1 | head -1)"
  echo "default sandbox: $SANDBOX_MODE"
  echo "out dir: $OUT_DIR"
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  require_codex_cli

  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.md"

  echo "[codex-cli-bridge] codex exec --sandbox $SANDBOX_MODE (timeout ${TIMEOUT_SEC}s)..." >&2
  if ! timeout "$TIMEOUT_SEC" codex exec --skip-git-repo-check -s "$SANDBOX_MODE" \
        "$prompt" > "$response_file" 2>&1; then
    die "codex exec failed or timed out. Partial output: $response_file" 1
  fi

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
}

cmd_review() {
  local prompt_file="${1:-}"
  [ -z "$prompt_file" ] && die "review: missing prompt-file path" 2
  [ ! -f "$prompt_file" ] && die "review: prompt file not found: $prompt_file" 2
  require_codex_cli

  local ts response_file slug verdict count
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(basename "$prompt_file" | sed 's/\.[^.]*$//')
  response_file="$OUT_DIR/review-$slug-$ts.md"

  echo "[codex-cli-bridge] codex exec for review (timeout ${TIMEOUT_SEC}s, sandbox $SANDBOX_MODE)..." >&2
  if ! timeout "$TIMEOUT_SEC" codex exec --skip-git-repo-check -s "$SANDBOX_MODE" \
        "$(cat "$prompt_file")" > "$response_file" 2>&1; then
    die "codex exec failed/timed out. Partial output: $response_file" 1
  fi

  verdict=$(extract_verdict "$response_file")
  count=$(extract_issues_count "$response_file")
  echo "VERDICT=$verdict"
  echo "ISSUES_COUNT=$count"
  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
}

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)   ROUTE_PROJECT="$2";  shift 2 ;;
      --thread)    ROUTE_THREAD="$2";   shift 2 ;;
      --mode)      ROUTE_MODE="$2";     shift 2 ;;
      --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
      --sandbox) SANDBOX_MODE="$2"; shift 2 ;;
      *)         REST+=("$1"); shift ;;
    esac
  done
}

case "$CMD" in
  list)   cmd_list ;;
  modes)  cmd_modes ;;
  status) cmd_status ;;
  ask)

    shift; parse_opts "$@"

    cmd_ask "$(inject_routing_context "${REST[0]:-}")"

    ;;
  review)

    shift; parse_opts "$@"

    load_frontmatter_route "${REST[0]:-}"

    _processed_prompt="/tmp/agent-bridge-prompt-$$.md"

    inject_routing_context "$(strip_frontmatter "${REST[0]:-}")" > "$_processed_prompt"

    cmd_review "$_processed_prompt"

    rm -f "$_processed_prompt"

    ;;
  ""|-h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# //'
    exit 0
    ;;
  *) die "unknown command: $CMD (try: status / ask / review)" 2 ;;
esac
