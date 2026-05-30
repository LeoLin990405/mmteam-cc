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

# ─── DOM SELECTOR CONFIG ──────────────────────────────────────────────
# Filled in after Leo's DevTools recon (Step 2 of the Trae SOLO Phase 2 plan).
# Update these 4 strings when TRAE SOLO UI changes (e.g. after app upgrade).
#
# How to find each:
#   - In TRAE SOLO with CDP up: Cmd+Shift+I → Cmd+Shift+C → click each element
#   - Prefer stable selectors: [data-*], unique aria-label, or class names
#     beginning with `chat-` / `prompt-` (avoid hash-suffixed VSCode classes
#     like `.monaco-list-row .codicon-xxxx`)

CHAT_INPUT_SELECTOR=""        # e.g. 'div[contenteditable="true"][data-test-id="chat-input"]'
SEND_BUTTON_SELECTOR=""       # e.g. 'button[aria-label="Send message"]'
RESPONSE_CONTAINER_SELECTOR="" # e.g. 'div[data-role="assistant-message"]:last-child'
DONE_SIGNAL_SELECTOR=""       # e.g. 'button[aria-label="Send message"]:not([disabled])'
                              # (button re-enabled = streaming done; or use a
                              # negative spinner class via DOM hash polling)
# ──────────────────────────────────────────────────────────────────────

CMD="${1:-}"
PORT=9235
SESSION="trae-solo"
TIMEOUT_SEC=600
OUT_DIR="/tmp/trae-solo-bridge"
mkdir -p "$OUT_DIR"

die() { echo "[trae-solo-bridge] $*" >&2; exit "${2:-1}"; }

check_selectors() {
  if [ -z "$CHAT_INPUT_SELECTOR" ] || [ -z "$SEND_BUTTON_SELECTOR" ] \
     || [ -z "$RESPONSE_CONTAINER_SELECTOR" ] || [ -z "$DONE_SIGNAL_SELECTOR" ]; then
    die "DOM selectors not filled in. Edit the SELECTOR CONFIG block at the top of this file." 2
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
  echo "=== Selectors configured ==="
  for k in CHAT_INPUT_SELECTOR SEND_BUTTON_SELECTOR RESPONSE_CONTAINER_SELECTOR DONE_SIGNAL_SELECTOR; do
    eval v=\$$k
    if [ -z "$v" ]; then
      echo "✗ $k = (empty — edit this file)"
    else
      echo "✓ $k = $v"
    fi
  done
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  check_cdp
  check_selectors

  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.md"

  echo "[trae-solo-bridge] bind CDP session :$PORT (timeout ${TIMEOUT_SEC}s)..." >&2
  opencli browser bind "$SESSION" 2>&1 | tail -3 >&2 || die "browser bind failed" 1

  echo "[trae-solo-bridge] fill chat input..." >&2
  opencli browser fill --selector "$CHAT_INPUT_SELECTOR" "$prompt" 2>&1 | tail -3 >&2 \
    || die "fill chat input failed (selector? $CHAT_INPUT_SELECTOR)" 1

  echo "[trae-solo-bridge] click send button..." >&2
  opencli browser click --selector "$SEND_BUTTON_SELECTOR" 2>&1 | tail -3 >&2 \
    || die "click send button failed (selector? $SEND_BUTTON_SELECTOR)" 1

  echo "[trae-solo-bridge] wait for done signal (timeout ${TIMEOUT_SEC}s)..." >&2
  opencli browser wait selector "$DONE_SIGNAL_SELECTOR" --timeout "$TIMEOUT_SEC" 2>&1 | tail -3 >&2 \
    || die "wait timed out — AI may still be generating, or DONE_SIGNAL_SELECTOR is wrong" 1

  echo "[trae-solo-bridge] extract response..." >&2
  opencli browser extract --selector "$RESPONSE_CONTAINER_SELECTOR" -f md > "$response_file" 2>&1 \
    || die "extract failed (selector? $RESPONSE_CONTAINER_SELECTOR)" 1

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
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
}

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)    PORT="$2"; shift 2 ;;
      --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
      *)         REST+=("$1"); shift ;;
    esac
  done
}

case "$CMD" in
  status) cmd_status ;;
  ask)    shift; parse_opts "$@"; cmd_ask "${REST[@]:-}" ;;
  review) shift; parse_opts "$@"; cmd_review "${REST[@]:-}" ;;
  ""|-h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# //'
    exit 0
    ;;
  *) die "unknown command: $CMD (try: status / ask / review)" 2 ;;
esac
