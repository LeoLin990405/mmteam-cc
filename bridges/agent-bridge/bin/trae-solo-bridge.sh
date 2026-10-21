#!/usr/bin/env bash
# trae-solo-bridge.sh — Drive TRAE SOLO via opencli generic browser over CDP :9235.
#
# Architecture:
#   Trae SOLO has no native opencli adapter (only 7 apps in opencli v1.8.0). This
#   bridge uses opencli's generic `browser` subcommand attached to TRAE SOLO's
#   CDP endpoint (port 9235, enabled by trae-solo-launch-with-cdp.sh).
#
#   Flow: bind CDP → fill chat input → click send → wait for completion signal
#         → extract response container → return text.
#
# Prerequisites:
#   1. TRAE SOLO running with --remote-debugging-port=9235 (run
#      ~/.claude/bin/trae-solo-launch-with-cdp.sh --bg)
#   2. opencli >= 1.8.0 in PATH
#   3. Chat panel open in TRAE SOLO (the iframe needs to be alive in the DOM)
#
# Usage:
#   trae-solo-bridge.sh status                          # ping CDP + verify chat panel
#   trae-solo-bridge.sh ask <text>    [--timeout S]     # sync prompt + wait + extract
#   trae-solo-bridge.sh review <file> [--timeout S]     # review loop + parse VERDICT

set -euo pipefail

source "$HOME/.claude/bin/_bridge_route.sh"
source "$HOME/.claude/bin/_bridge_delete.sh"

cmd_delete() {
  parse_delete_args "$@"
  if [ -z "$DELETE_ID" ] && [ "$DELETE_ALL" != "1" ]; then
    echo "[trae-solo:delete] need <session-id> or --all." >&2
    echo "  Get ids: agent-bridge trae-solo list | jq '.sessions[].id'" >&2
    exit 2
  fi
  delete_banner "trae-solo" "delete chat session via CDP click" "${DELETE_ID:-ALL}"
  if [ "$DELETE_DRY_RUN" = "1" ]; then return 0; fi
  echo "[trae-solo:delete] NOT IMPLEMENTED — CDP click selector for delete menu unknown." >&2
  echo "  Workaround: TRAE SOLO UI → hover session row → 3-dot menu → Delete chat." >&2
  echo "  TODO: add cmd_delete to ~/.claude/bin/_trae-solo-cdp.py once selector known." >&2
  exit 1
}

# ─── ARCHITECTURE NOTE ────────────────────────────────────────────────
# Selectors are kept in the Python helper (~/.claude/bin/_trae-solo-cdp.py)
# because TRAE SOLO uses Lexical editor (Facebook framework) which needs
# clipboard-paste event synthesis — bash + opencli `browser fill` can't
# replicate that. The helper talks to TRAE SOLO over CDP WebSocket directly.
#
# Done-signal strategy: DOM-hash idle detection (poll last message outerHTML
# every 0.5s; 4s of stable hash → AI finished streaming). More robust than
# button-class check because Trae SOLO disables send button both during
# streaming AND when input is empty.
#
# Update _trae-solo-cdp.py's SELECTOR CONFIG block if Trae SOLO UI changes.
# ──────────────────────────────────────────────────────────────────────

CDP_HELPER="$HOME/.claude/bin/_trae-solo-cdp.py"
# Use the agent-bridge venv if it exists; otherwise system python3 (must have
# websocket-client installed: pip install --break-system-packages websocket-client)
if [ -x "$HOME/.claude/bin/.venv/bin/python3" ]; then
  PYTHON="$HOME/.claude/bin/.venv/bin/python3"
elif [ -x "$HOME/Projects/nd0044-fyyur/.venv/bin/python3" ]; then
  PYTHON="$HOME/Projects/nd0044-fyyur/.venv/bin/python3"
else
  PYTHON="python3"
fi

CMD="${1:-}"
PORT=9235
SESSION="trae-solo"
TIMEOUT_SEC=600
OUT_DIR="/tmp/trae-solo-bridge"
mkdir -p "$OUT_DIR"

die() { echo "[trae-solo-bridge] $*" >&2; exit "${2:-1}"; }

check_helper() {
  if [ ! -f "$CDP_HELPER" ]; then
    die "CDP helper missing: $CDP_HELPER" 2
  fi
  if ! "$PYTHON" -c "import websocket" 2>/dev/null; then
    die "websocket-client not installed for $PYTHON. Run: $PYTHON -m pip install websocket-client" 2
  fi
}

check_cdp() {
  if ! curl -s --max-time 1 "http://localhost:$PORT/json/version" | grep -q "Browser" 2>/dev/null; then
    die "TRAE SOLO CDP not on :$PORT. Run ~/.claude/bin/trae-solo-launch-with-cdp.sh first." 1
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

cmd_status() {
  echo "=== TRAE SOLO CDP (port $PORT) ==="
  if curl -s --max-time 2 "http://localhost:$PORT/json/version" | grep -q "Browser"; then
    echo "✓ CDP up"
    curl -s "http://localhost:$PORT/json/version" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'  Browser: {d.get(\"Browser\",\"?\")}')
print(f'  UA: {d.get(\"User-Agent\",\"?\")[:80]}')
"
  else
    echo "✗ CDP not up — run trae-solo-launch-with-cdp.sh"
    exit 1
  fi
  echo
  echo "=== Python CDP helper ==="
  if [ ! -f "$CDP_HELPER" ]; then
    echo "✗ helper missing: $CDP_HELPER"
  elif ! "$PYTHON" -c "import websocket" 2>/dev/null; then
    echo "✗ websocket-client not installed for $PYTHON"
    echo "  fix: $PYTHON -m pip install --break-system-packages websocket-client"
  else
    echo "✓ helper ready: $CDP_HELPER"
    echo "✓ python: $PYTHON"
    "$PYTHON" "$CDP_HELPER" status --port "$PORT" 2>&1 | sed 's/^/  /'
  fi
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  check_cdp
  check_helper

  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.md"

  echo "[trae-solo-bridge] ask via CDP helper (timeout ${TIMEOUT_SEC}s)..." >&2
  if ! "$PYTHON" "$CDP_HELPER" ask "$prompt" --port "$PORT" --timeout "$TIMEOUT_SEC" > "$response_file" 2>>"$response_file.stderr"; then
    cat "$response_file.stderr" >&2
    die "trae-solo-cdp ask failed; partial output: $response_file" 1
  fi

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "trae-solo"
}

cmd_review() {
  local prompt_file="${1:-}"
  [ -z "$prompt_file" ] && die "review: missing prompt-file path" 2
  [ ! -f "$prompt_file" ] && die "review: prompt file not found: $prompt_file" 2

  cmd_ask "$(cat "$prompt_file")" > /tmp/trae-solo-bridge-cur.out
  local response_file verdict count
  response_file=$(grep -oE 'RESPONSE_FILE=.*' /tmp/trae-solo-bridge-cur.out | head -1 | cut -d= -f2)
  verdict=$(extract_verdict "$response_file")
  count=$(extract_issues_count "$response_file")

  echo "VERDICT=$verdict"
  echo "ISSUES_COUNT=$count"
  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "trae-solo"
}

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)    PORT="$2"; shift 2 ;;
      --project)   ROUTE_PROJECT="$2";  shift 2 ;;
      --thread)    ROUTE_THREAD="$2";   shift 2 ;;
      --mode)      ROUTE_MODE="$2";     shift 2 ;;
      --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
      *)         REST+=("$1"); shift ;;
    esac
  done
}

case "$CMD" in
  status) cmd_status ;;
  list)   exec "$PYTHON" "$CDP_HELPER" list --port "$PORT" ;;
  modes)  exec "$PYTHON" "$CDP_HELPER" modes --port "$PORT" ;;
  delete) shift; cmd_delete "$@" ;;
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
