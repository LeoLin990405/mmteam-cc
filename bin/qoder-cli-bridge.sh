#!/usr/bin/env bash
# qoder-cli-bridge.sh — Drive `qodercli` (Alibaba Qoder AI terminal CLI) as a bridge surface.
#
# Mirror of codex-cli-bridge.sh but for qodercli — same 3 verbs, same output shape.
# Underlying: qodercli -p <prompt> -f json --max-turns N --disallowed-tools <list>
#
# IMPORTANT:
#   - qodercli != /Users/leo/.local/bin/qoder (that's the VSCode-style file opener,
#     NOT the AI CLI). The AI CLI is at /Users/leo/.npm-global/bin/qodercli (0.1.46).
#   - First-time use requires OAuth login: run `qodercli status` interactively once.
#   - This uses your Qoder Coding Plan / Token Plan quota.
#
# Usage:
#   qoder-cli-bridge.sh status
#   qoder-cli-bridge.sh ask    <text>      [--timeout S] [--max-turns N]
#   qoder-cli-bridge.sh review <prompt-file> [--timeout S] [--max-turns N]
#
# review output (same shape as codex-cli-bridge for unified Claude consumption):
#   VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
#   ISSUES_COUNT=N
#   RESPONSE_FILE=/tmp/qoder-cli-bridge/...md
#   ---
#   <full markdown response>

set -euo pipefail

source "$HOME/.claude/bin/_bridge_route.sh"

CMD="${1:-}"
TIMEOUT_SEC=600
MAX_TURNS=25
# Review-mode disallowed tools: Qoder must NOT modify code; Claude patches NEEDS_FIX.
DISALLOWED_TOOLS_REVIEW="Edit,Write,MultiEdit,NotebookEdit"
OUT_DIR="/tmp/qoder-cli-bridge"
mkdir -p "$OUT_DIR"

die() { echo "[qoder-cli-bridge] $*" >&2; exit "${2:-1}"; }

require_qodercli() {
  if ! command -v qodercli >/dev/null 2>&1; then
    die "qodercli not found in PATH. Install: npm i -g qodercli (or check ~/.npm-global/bin/qodercli)" 1
  fi
}

extract_verdict() {
  # Try JSON content first, fall back to plain text scan
  python3 -c "
import json, sys, re
try:
    raw = open(sys.argv[1]).read()
    # Qoder JSON output may wrap result in various ways; try to parse
    try:
        d = json.loads(raw)
        text = d.get('result') or d.get('response') or d.get('content') or json.dumps(d)
        if isinstance(text, list):
            text = ' '.join(str(b.get('text', b)) for b in text)
    except json.JSONDecodeError:
        text = raw
    m = re.search(r'VERDICT:\s*(ACCEPTED|NEEDS[ _-]?FIX)', text, re.I)
    if not m:
        m = re.search(r'^(ACCEPTED|NEEDS[ _-]?FIX)\b', text, re.I | re.M)
    print(m.group(1).upper().replace(' ', '_').replace('-', '_') if m else 'UNKNOWN')
except Exception as e:
    print('UNKNOWN')
" "$1"
}

extract_issues_count() {
  python3 -c "
import json, sys, re
try:
    raw = open(sys.argv[1]).read()
    try:
        d = json.loads(raw)
        text = d.get('result') or d.get('response') or d.get('content') or json.dumps(d)
        if isinstance(text, list):
            text = ' '.join(str(b.get('text', b)) for b in text)
    except json.JSONDecodeError:
        text = raw
    # Look for 'Issues found' section, count numbered items
    in_section = False
    count = 0
    for line in text.splitlines():
        if re.match(r'^#{1,3}\s*Issues\s+found', line, re.I):
            in_section = True
            continue
        if in_section and re.match(r'^#{1,3}\s', line):
            break
        if in_section and re.match(r'^\s*\d+\.', line):
            count += 1
    print(count)
except Exception:
    print(0)
" "$1"
}

cmd_list() {
  # qodercli has a `jobs` subcommand for concurrent jobs.
  require_qodercli
  local jobs_raw
  jobs_raw=$(qodercli jobs 2>&1 || true)
  python3 <<PYEOF
import json
raw = """$jobs_raw"""
print(json.dumps({
    "surface": "qoder-cli",
    "stateless": True,
    "active_session": None,
    "concurrent_jobs_raw": raw[:500],
    "note": "qodercli sessions are stateless per-invocation; --continue (-c) flag resumes the most recent. 'qodercli jobs' lists in-flight concurrent jobs."
}, indent=2))
PYEOF
}

cmd_modes() {
  python3 <<PYEOF
import json
print(json.dumps({
    "surface": "qoder-cli",
    "axis": "agent-config",
    "active_mode": "default",
    "available_modes": [
        "--allowed-tools <list>",
        "--disallowed-tools <list> (used by review)",
        "--max-turns <N>",
        "--dangerously-skip-permissions",
        "--agents <json>  (define custom agents)"
    ],
    "note": "Qoder CLI's mode axis is the agent-config flags. Review path uses --disallowed-tools 'Edit,Write' to prevent code modification."
}, indent=2))
PYEOF
}

cmd_status() {
  require_qodercli
  echo "qodercli: $(command -v qodercli)"
  echo "version: $(qodercli --version 2>&1 | head -1)"
  echo "(run 'qodercli status' interactively to check OAuth login state)"
  echo "out dir: $OUT_DIR"
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  require_qodercli

  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.json"

  echo "[qoder-cli-bridge] qodercli -p -f json --max-turns $MAX_TURNS (timeout ${TIMEOUT_SEC}s)..." >&2
  if ! timeout "$TIMEOUT_SEC" qodercli -p "$prompt" -f json --max-turns "$MAX_TURNS" \
        > "$response_file" 2>&1; then
    die "qodercli failed/timed out. Partial output: $response_file" 1
  fi

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "qoder-cli"
}

cmd_review() {
  local prompt_file="${1:-}"
  [ -z "$prompt_file" ] && die "review: missing prompt-file path" 2
  [ ! -f "$prompt_file" ] && die "review: prompt file not found: $prompt_file" 2
  require_qodercli

  local ts response_file slug verdict count
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(basename "$prompt_file" | sed 's/\.[^.]*$//')
  response_file="$OUT_DIR/review-$slug-$ts.json"

  echo "[qoder-cli-bridge] qodercli review (timeout ${TIMEOUT_SEC}s, max-turns $MAX_TURNS, no Edit/Write)..." >&2
  if ! timeout "$TIMEOUT_SEC" qodercli -p "$(cat "$prompt_file")" \
        -f json \
        --max-turns "$MAX_TURNS" \
        --disallowed-tools "$DISALLOWED_TOOLS_REVIEW" \
        > "$response_file" 2>&1; then
    die "qodercli failed/timed out. Partial output: $response_file" 1
  fi

  verdict=$(extract_verdict "$response_file")
  count=$(extract_issues_count "$response_file")
  echo "VERDICT=$verdict"
  echo "ISSUES_COUNT=$count"
  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "qoder-cli"
}

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)   ROUTE_PROJECT="$2";  shift 2 ;;
      --thread)    ROUTE_THREAD="$2";   shift 2 ;;
      --mode)      ROUTE_MODE="$2";     shift 2 ;;
      --timeout)   TIMEOUT_SEC="$2"; shift 2 ;;
      --max-turns) MAX_TURNS="$2"; shift 2 ;;
      *)           REST+=("$1"); shift ;;
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
