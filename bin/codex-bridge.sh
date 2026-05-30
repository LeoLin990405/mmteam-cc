#!/usr/bin/env bash
# codex-bridge.sh — Drive Codex Desktop App via opencli for closed-loop review.
#
# Usage:
#   codex-bridge.sh review  <prompt-file> [--out <export-dir>] [--timeout <sec>]
#   codex-bridge.sh ask     <prompt-text>                         [--timeout <sec>]
#   codex-bridge.sh status
#
# review: opens a new Codex thread, sends the prompt-file contents, blocks until
#         Codex finishes, exports the full markdown response, prints a structured
#         summary to stdout:
#
#           VERDICT=<ACCEPTED|NEEDS_FIX|UNKNOWN>
#           RESPONSE_FILE=<path/to/exported.md>
#           ISSUES_COUNT=<N>
#           ---
#           <full markdown response>
#
# Exit codes:
#   0 = OK (Codex responded; check VERDICT line)
#   1 = opencli error / Codex not connected / timeout
#   2 = usage error
#
# Notes:
#   - Requires Codex Desktop App running and CDP-reachable (`opencli codex status`
#     prints "Connected").
#   - `opencli codex ask` is synchronous and blocks until Codex finishes streaming.
#   - Default timeout 600s (10 min). Long reviews may need --timeout 1200.

set -euo pipefail

CMD="${1:-}"
TIMEOUT_SEC=600
OUT_DIR="/tmp/codex-bridge"
mkdir -p "$OUT_DIR"

# -------- helpers --------
die() { echo "[codex-bridge] $*" >&2; exit "${2:-1}"; }

require_codex_connected() {
  local st
  st=$(opencli codex status 2>&1 | grep -i "^- Status:" | awk -F: '{print $2}' | xargs)
  if [ "$st" != "Connected" ]; then
    die "Codex Desktop not connected via CDP (status: '$st'). Open Codex app first." 1
  fi
}

extract_verdict() {
  # Match "VERDICT: ACCEPTED" / "VERDICT: NEEDS FIX" / fallback "ACCEPTED — " / "NEEDS FIX —"
  local v
  v=$(grep -oiE 'VERDICT:\s*(ACCEPTED|NEEDS[ _-]?FIX)' "$1" 2>/dev/null | head -1 | awk -F: '{print $2}' | xargs | tr '[:lower:]' '[:upper:]' | tr ' ' '_')
  if [ -z "$v" ]; then
    v=$(grep -oE '^(ACCEPTED|NEEDS[ _-]?FIX)\b' "$1" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]' | tr ' ' '_')
  fi
  [ -z "$v" ] && v="UNKNOWN"
  echo "$v"
}

extract_issues_count() {
  # Count numbered list items under "Issues found" section
  awk '
    /^###?[[:space:]]*Issues[[:space:]]+found/i { in_issues=1; next }
    in_issues && /^###/ { exit }
    in_issues && /^[[:space:]]*[0-9]+\./ { c++ }
    END { print c+0 }
  ' "$1" 2>/dev/null
}

# -------- subcommands --------
cmd_status() {
  # Direct CDP ping (does NOT trigger opencli's slow probe-and-restart logic).
  local port=9238
  echo "=== Codex Desktop App CDP (port $port) ==="
  if curl -s --max-time 2 "http://localhost:$port/json/version" | grep -q "Browser" 2>/dev/null; then
    echo "✓ CDP up"
    curl -s "http://localhost:$port/json/version" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'  Browser: {d.get(\"Browser\",\"?\")}')
print(f'  UA: {d.get(\"User-Agent\",\"?\")[:80]}')
" 2>/dev/null
  else
    echo "✗ CDP not up on :$port — run ~/.claude/bin/codex-launch-with-cdp.sh"
  fi
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  require_codex_connected

  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.md"

  echo "[codex-bridge] ask: new thread + send (timeout ${TIMEOUT_SEC}s)..."
  opencli codex new > /dev/null
  timeout "$TIMEOUT_SEC" opencli codex ask "$prompt" -f md > "$response_file" 2>&1 || die "opencli codex ask failed/timed out" 1

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
}

cmd_review() {
  local prompt_file="${1:-}"
  [ -z "$prompt_file" ] && die "review: missing prompt-file path" 2
  [ ! -f "$prompt_file" ] && die "review: prompt file not found: $prompt_file" 2
  require_codex_connected

  local ts response_file export_file slug
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(basename "$prompt_file" | sed 's/\.[^.]*$//')
  response_file="$OUT_DIR/review-$slug-$ts.md"
  export_file="$OUT_DIR/review-$slug-$ts.export.md"

  echo "[codex-bridge] review: opening fresh Codex thread..." >&2
  opencli codex new > /dev/null

  echo "[codex-bridge] review: sending prompt (timeout ${TIMEOUT_SEC}s), Codex is working..." >&2
  if ! timeout "$TIMEOUT_SEC" opencli codex ask "$(cat "$prompt_file")" -f md > "$response_file" 2>&1; then
    die "opencli codex ask failed or timed out after ${TIMEOUT_SEC}s. Response so far: $response_file" 1
  fi

  echo "[codex-bridge] review: exporting full thread for archive..." >&2
  opencli codex export -f md > "$export_file" 2>&1 || true   # non-fatal

  local verdict count
  verdict=$(extract_verdict "$response_file")
  count=$(extract_issues_count "$response_file")

  echo "VERDICT=$verdict"
  echo "ISSUES_COUNT=$count"
  echo "RESPONSE_FILE=$response_file"
  echo "EXPORT_FILE=$export_file"
  echo "---"
  cat "$response_file"
}

# -------- arg parsing for --timeout --out --------
parse_opts() {
  local out
  out=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
      --out)     OUT_DIR="$2"; mkdir -p "$OUT_DIR"; shift 2 ;;
      *)         out+=("$1"); shift ;;
    esac
  done
  REST=("${out[@]}")
}

case "$CMD" in
  status)
    cmd_status
    ;;
  ask)
    shift
    parse_opts "$@"
    cmd_ask "${REST[@]}"
    ;;
  review)
    shift
    parse_opts "$@"
    cmd_review "${REST[@]}"
    ;;
  ""|-h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# //'
    exit 0
    ;;
  *)
    die "unknown command: $CMD (try: status / ask / review)" 2
    ;;
esac
