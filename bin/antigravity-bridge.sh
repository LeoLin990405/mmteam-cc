#!/usr/bin/env bash
# antigravity-bridge.sh — Drive Antigravity via opencli serve (HTTP).
#
# Architecture:
#   Antigravity exposes /v1/messages HTTP endpoint (via `opencli antigravity serve`).
#   This script POSTs the prompt and waits for the HTTP response synchronously —
#   the response IS the "agent completed" signal. No polling, no hashing.
#
# Prerequisites:
#   1. Antigravity launched with CDP 9234: ~/.claude/bin/antigravity-launch-with-cdp.sh
#   2. Serve daemon running:                ~/.claude/bin/antigravity-serve-up.sh
#
# Usage:
#   antigravity-bridge.sh status                     # ping CDP + serve
#   antigravity-bridge.sh ask <text>    [--port P] [--timeout S]
#   antigravity-bridge.sh review <prompt-file> [--port P] [--timeout S]
#
# review output (same shape as codex-bridge for unified Claude consumption):
#   VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
#   ISSUES_COUNT=N
#   RESPONSE_FILE=/tmp/antigravity-bridge/...md
#   ---
#   <full markdown response>

set -euo pipefail

CMD="${1:-}"
PORT=8082
TIMEOUT_SEC=600
OUT_DIR="/tmp/antigravity-bridge"
mkdir -p "$OUT_DIR"

die() { echo "[antigravity-bridge] $*" >&2; exit "${2:-1}"; }

check_serve() {
  if ! curl -s --max-time 1 -X OPTIONS "http://localhost:$PORT/v1/messages" -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^(200|204|404|405)$'; then
    die "Antigravity serve not on :$PORT. Run: ~/.claude/bin/antigravity-serve-up.sh" 1
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
  echo "=== Antigravity CDP (port 9234) ==="
  if curl -s --max-time 2 "http://localhost:9234/json/version" | grep -q "Browser"; then
    echo "✓ CDP up"
  else
    echo "✗ CDP not up — run antigravity-launch-with-cdp.sh"
  fi
  echo
  echo "=== Antigravity serve (port $PORT) ==="
  if curl -s --max-time 1 -X OPTIONS "http://localhost:$PORT/v1/messages" -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^(200|204|404|405)$'; then
    echo "✓ serve listening"
  else
    echo "✗ serve not listening — run antigravity-serve-up.sh"
  fi
}

http_post() {
  # POST a Messages request, return the parsed text content.
  local prompt="$1" raw_file="$2" text_file="$3"
  local req
  req=$(python3 -c "
import json, sys
print(json.dumps({
  'model': 'claude-3-5-sonnet',
  'max_tokens': 16384,
  'messages': [{'role': 'user', 'content': sys.argv[1]}]
}))
" "$prompt")

  curl -s --max-time "$TIMEOUT_SEC" \
    -X POST "http://localhost:$PORT/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: dummy" \
    -H "anthropic-version: 2023-06-01" \
    -d "$req" \
    -o "$raw_file" \
    || die "HTTP POST failed (timeout after ${TIMEOUT_SEC}s?). Raw: $raw_file" 1

  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f'[antigravity-bridge] JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)
if 'content' in d and isinstance(d['content'], list):
    for block in d['content']:
        if block.get('type') == 'text':
            print(block.get('text', ''))
elif 'error' in d:
    print(json.dumps(d, indent=2), file=sys.stderr)
    sys.exit(1)
else:
    print(json.dumps(d, indent=2))
" "$raw_file" > "$text_file"
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  check_serve
  local ts raw_file text_file
  ts=$(date +%Y%m%d-%H%M%S)
  raw_file="$OUT_DIR/ask-$ts.json"
  text_file="$OUT_DIR/ask-$ts.md"
  echo "[antigravity-bridge] POST /v1/messages (timeout ${TIMEOUT_SEC}s)..." >&2
  http_post "$prompt" "$raw_file" "$text_file"
  echo "RESPONSE_FILE=$text_file"
  echo "RAW_FILE=$raw_file"
  echo "---"
  cat "$text_file"
}

cmd_review() {
  local prompt_file="${1:-}"
  [ -z "$prompt_file" ] && die "review: missing prompt-file path" 2
  [ ! -f "$prompt_file" ] && die "review: prompt file not found: $prompt_file" 2
  check_serve

  local ts raw_file text_file slug verdict count
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(basename "$prompt_file" | sed 's/\.[^.]*$//')
  raw_file="$OUT_DIR/review-$slug-$ts.json"
  text_file="$OUT_DIR/review-$slug-$ts.md"

  echo "[antigravity-bridge] POST /v1/messages for review (timeout ${TIMEOUT_SEC}s)..." >&2
  http_post "$(cat "$prompt_file")" "$raw_file" "$text_file"

  verdict=$(extract_verdict "$text_file")
  count=$(extract_issues_count "$text_file")
  echo "VERDICT=$verdict"
  echo "ISSUES_COUNT=$count"
  echo "RESPONSE_FILE=$text_file"
  echo "RAW_FILE=$raw_file"
  echo "---"
  cat "$text_file"
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
