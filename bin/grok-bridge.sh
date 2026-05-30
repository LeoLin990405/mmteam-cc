#!/usr/bin/env bash
# grok-bridge.sh — Drive Grok web (grok.com) via CDP on a dedicated Chrome
# instance launched by grok-launch-with-cdp.sh.
#
# Prerequisites:
#   1. Chrome (Google Chrome / Chromium / Brave / Edge) installed
#   2. ~/.claude/bin/grok-launch-with-cdp.sh --bg     # boots a CDP Chrome
#      and Leo logs in once; cookies persist in the dedicated profile.
#   3. python3 with websocket-client (auto-detected from venvs)
#
# Usage:
#   grok-bridge.sh status                               # ping CDP + tab presence
#   grok-bridge.sh list                                 # enumerate conversation list
#   grok-bridge.sh modes                                # (Grok's mode axis = model)
#   grok-bridge.sh ask    <prompt>     [--timeout S] [--idle SEC]
#   grok-bridge.sh review <prompt-file> [--timeout S]
#   grok-bridge.sh probe-selectors                      # diagnostic
#
# review output (unified with the other bridges):
#   VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
#   ISSUES_COUNT=N
#   RESPONSE_FILE=/tmp/grok-bridge/...md
#   ---
#   <full markdown response>

set -euo pipefail

source "$HOME/.claude/bin/_bridge_route.sh"
source "$HOME/.claude/bin/_bridge_delete.sh"

CDP_HELPER="$HOME/.claude/bin/_grok-cdp.py"
if [ -x "$HOME/.claude/bin/.venv/bin/python3" ]; then
  PYTHON="$HOME/.claude/bin/.venv/bin/python3"
elif [ -x "$HOME/Projects/nd0044-fyyur/.venv/bin/python3" ]; then
  PYTHON="$HOME/Projects/nd0044-fyyur/.venv/bin/python3"
else
  PYTHON="python3"
fi

CMD="${1:-}"
PORT=9237
TIMEOUT_SEC=600
IDLE_SEC=8
OUT_DIR="/tmp/grok-bridge"
mkdir -p "$OUT_DIR"

die() { echo "[grok-bridge] $*" >&2; exit "${2:-1}"; }

check_helper() {
  [ -f "$CDP_HELPER" ] || die "CDP helper missing: $CDP_HELPER" 2
  "$PYTHON" -c "import websocket" 2>/dev/null || die "websocket-client not installed for $PYTHON. Run: $PYTHON -m pip install --break-system-packages websocket-client" 2
}

check_cdp() {
  curl -s --max-time 1 "http://localhost:$PORT/json/version" | grep -q "Browser" 2>/dev/null \
    || die "Grok CDP not on :$PORT. Run ~/.claude/bin/grok-launch-with-cdp.sh first." 1
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

cmd_modes() {
  python3 <<'PYEOF'
import json
print(json.dumps({
    "surface": "grok",
    "axis": "model",
    "active_mode": "(unknown — set via Grok UI model picker)",
    "available_modes": ["grok-2", "grok-3", "grok-3-think", "grok-4", "grok-4-heavy"],
    "note": "Grok's mode axis is its model picker in the chat UI. No programmatic switch yet."
}, indent=2))
PYEOF
}

cmd_status() {
  echo "=== Grok Chrome CDP (port $PORT) ==="
  if curl -s --max-time 2 "http://localhost:$PORT/json/version" | grep -q "Browser"; then
    echo "✓ CDP up"
  else
    echo "✗ CDP not up — run grok-launch-with-cdp.sh first"
    exit 1
  fi
  echo
  echo "=== CDP helper / Python ==="
  if "$PYTHON" -c "import websocket" 2>/dev/null; then
    echo "✓ websocket-client ready ($PYTHON)"
    "$PYTHON" "$CDP_HELPER" status --port "$PORT" 2>&1 | sed 's/^/  /'
  else
    echo "✗ websocket-client missing for $PYTHON"
  fi
}

cmd_list() {
  check_cdp
  check_helper
  exec "$PYTHON" "$CDP_HELPER" list --port "$PORT"
}

cmd_probe_selectors() {
  check_cdp
  check_helper
  exec "$PYTHON" "$CDP_HELPER" probe-selectors --port "$PORT"
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  check_cdp
  check_helper
  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.md"

  echo "[grok-bridge] ask via CDP helper (timeout ${TIMEOUT_SEC}s, idle ${IDLE_SEC}s)..." >&2
  if ! "$PYTHON" "$CDP_HELPER" ask "$prompt" --port "$PORT" --timeout "$TIMEOUT_SEC" --idle "$IDLE_SEC" > "$response_file" 2>>"$response_file.stderr"; then
    cat "$response_file.stderr" >&2
    die "grok-cdp ask failed; partial output: $response_file" 1
  fi

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "grok"
}

cmd_review() {
  local prompt_file="${1:-}"
  [ -z "$prompt_file" ] && die "review: missing prompt-file path" 2
  [ ! -f "$prompt_file" ] && die "review: prompt file not found: $prompt_file" 2

  cmd_ask "$(cat "$prompt_file")" > /tmp/grok-bridge-cur.out
  local response_file verdict count
  response_file=$(grep -oE 'RESPONSE_FILE=.*' /tmp/grok-bridge-cur.out | head -1 | cut -d= -f2)
  verdict=$(extract_verdict "$response_file")
  count=$(extract_issues_count "$response_file")

  echo "VERDICT=$verdict"
  echo "ISSUES_COUNT=$count"
  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "grok"
}

cmd_delete() {
  parse_delete_args "$@"
  delete_banner "grok" "delete conversation via CDP click trash icon" "${DELETE_ID:-ALL}"
  if [ "$DELETE_DRY_RUN" = "1" ]; then return 0; fi
  echo "[grok:delete] NOT IMPLEMENTED — CDP click selector for delete unknown." >&2
  echo "  Workaround: in Grok UI, hover conversation → trash icon." >&2
  exit 1
}

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)      PORT="$2"; shift 2 ;;
      --project)   ROUTE_PROJECT="$2"; shift 2 ;;
      --thread)    ROUTE_THREAD="$2";  shift 2 ;;
      --mode)      ROUTE_MODE="$2";    shift 2 ;;
      --timeout)   TIMEOUT_SEC="$2";   shift 2 ;;
      --idle)      IDLE_SEC="$2";      shift 2 ;;
      *)           REST+=("$1");       shift ;;
    esac
  done
}

case "$CMD" in
  status)             cmd_status ;;
  list)               cmd_list ;;
  modes)              cmd_modes ;;
  probe-selectors)    cmd_probe_selectors ;;
  delete)             shift; cmd_delete "$@" ;;
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
  *) die "unknown command: $CMD (try: status / list / modes / ask / review / probe-selectors / delete)" 2 ;;
esac
