#!/usr/bin/env bash
# grok-bridge.sh — Drive Grok web (grok.com) via the user's main Chrome
# using opencli's official Browser Bridge (extension + daemon, port 19825).
#
# REVISION 2026-05-31 (v2): rewritten after finding the real selectors.
#
# What we learned (the hard way):
#   1. The visible "今天需要我如何帮助你？" / "Ask me anything..." placeholder is
#      NOT on a <textarea> — Grok uses Tiptap (ProseMirror) on a
#      <div contenteditable="true" role="textbox" aria-label="Ask Grok anything">.
#   2. opencli's `fill` / `type` won't work on Tiptap. Use:
#         document.execCommand('insertText', false, prompt)
#      to dispatch a beforeinput event that ProseMirror listens to.
#   3. The send button is NOT in the form until you fill content. Once the
#      div has text, the voice-mode mic morphs into <button data-testid="chat-submit">
#      with visible label "提交" (Submit).
#   4. The Aitopia browser extension Leo has installed renders its own
#      <textarea placeholder="Ask me anything..."> in a sidebar — easy to
#      mistake for Grok's input. Always select by aria-label="Ask Grok anything".
#
# Verified 2026-05-31: ask sends, URL transitions /  → /c/<uuid>?rid=<uuid>.

set -euo pipefail

source "$HOME/.claude/bin/_bridge_route.sh"
source "$HOME/.claude/bin/_bridge_delete.sh"

CMD="${1:-}"
SESSION="grok"
GROK_URL="https://grok.com/"
TIMEOUT_SEC=600
IDLE_SEC=4
OUT_DIR="/tmp/grok-bridge"
mkdir -p "$OUT_DIR"

# Real Grok selectors (verified 2026-05-31)
INPUT_SEL='[contenteditable="true"][aria-label="Ask Grok anything"]'
SUBMIT_SEL='button[data-testid="chat-submit"]'

die() { echo "[grok-bridge] $*" >&2; exit "${2:-1}"; }

check_extension() {
  local doc
  doc=$(opencli doctor 2>&1 | tr -d '\r')
  if ! echo "$doc" | grep -q "\[OK\] Extension"; then
    die "opencli Chrome extension not connected. Install:
  1. Open chrome://extensions/ in your main Chrome
  2. Enable 'Developer mode' (top-right)
  3. 'Load unpacked' → /Users/leo/Projects/OpenCLI/extension
  4. Re-run: opencli doctor   (should show [OK] Extension: connected)" 1
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
  echo "=== opencli daemon + extension ==="
  opencli doctor 2>&1 | grep -E "^\[(OK|FAIL|MISSING)\]" | head -5
  echo
  echo "=== Grok session state ==="
  local probe
  probe=$(opencli browser "$SESSION" eval "(() => {
    const input = document.querySelector('$INPUT_SEL');
    return {
      url: location.href,
      title: document.title,
      input_ready: !!input,
      logged_in: !location.href.includes('accounts.google'),
    };
  })()" 2>/dev/null | tail -10)
  if [ -n "$probe" ]; then
    echo "$probe"
  else
    echo "  ✗ session '$SESSION' not bound — open grok.com in main Chrome then run 'grok-bridge.sh bind'"
  fi
}

cmd_bind() {
  check_extension
  echo "[grok-bridge] binding active Chrome tab to session '$SESSION'..." >&2
  opencli browser "$SESSION" bind 2>&1 | head -5
}

cmd_modes() {
  python3 <<'PYEOF'
import json
print(json.dumps({
    "surface": "grok",
    "axis": "model",
    "active_mode": "(set in Grok UI via 'Fast'/'Expert' picker)",
    "available_modes": ["grok-3", "grok-3-think", "grok-4", "grok-4-heavy"],
    "note": "Free tier defaults to grok-3 'Fast'. Programmatic switch via the model-select-trigger button (ref via list)."
}, indent=2))
PYEOF
}

cmd_list() {
  check_extension
  local raw
  raw=$(opencli browser "$SESSION" eval "(() => {
    return {
      url: location.href,
      title: document.title,
      logged_in: !location.href.includes('accounts.google') && location.href.includes('grok.com'),
      input_ready: !!document.querySelector('$INPUT_SEL'),
      conv_links: Array.from(document.querySelectorAll('a[href*=\"/c/\"]')).slice(0, 10).map(a => ({
        href: a.getAttribute('href'),
        text: (a.textContent||'').trim().slice(0, 50)
      })),
    };
  })()" 2>/dev/null)
  python3 -c "
import json, re, sys
raw = '''$raw'''
m = re.search(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', raw, re.DOTALL)
try:
    inner = json.loads(m.group(0)) if m else {}
except Exception:
    inner = {}
print(json.dumps({
    'surface': 'grok',
    'session': '$SESSION',
    'active_session': 'current',
    'page_url': inner.get('url', ''),
    'page_title': inner.get('title', ''),
    'logged_in': bool(inner.get('logged_in')),
    'input_ready': bool(inner.get('input_ready')),
    'conv_links_count': len(inner.get('conv_links', [])),
    'recent_conversations': inner.get('conv_links', [])[:5],
    'sessions': [{'id': c.get('href'), 'title': c.get('text')} for c in inner.get('conv_links', [])[:10]] or [{'id': 'current', 'title': inner.get('title','grok')[:60]}],
    'note': 'main Chrome via opencli extension'
}, indent=2, ensure_ascii=False))
"
}

_ensure_grok_page() {
  local cur_url
  cur_url=$(opencli browser "$SESSION" eval "location.href" 2>/dev/null | tail -3 | grep -oE 'https?://[^"]+' | head -1)
  if [[ "$cur_url" != *"grok.com"* ]]; then
    echo "[grok-bridge] opening $GROK_URL (was on ${cur_url:-unknown})..." >&2
    opencli browser "$SESSION" open "$GROK_URL" 2>&1 | tail -2
    sleep 3
  fi
}

cmd_ask() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && die "ask: missing prompt text" 2
  check_extension

  local ts response_file
  ts=$(date +%Y%m%d-%H%M%S)
  response_file="$OUT_DIR/ask-$ts.md"

  _ensure_grok_page

  # 1. Wait for the Tiptap input to be present
  echo "[grok-bridge] waiting for Tiptap chat input..." >&2
  opencli browser "$SESSION" wait selector "$INPUT_SEL" --timeout 15 >/dev/null 2>&1 || \
    die "Grok chat input not found. Are you logged in?" 1

  # 2. Fill via execCommand insertText (Tiptap/ProseMirror compatible).
  #    JSON-escape the prompt so it can ride inside the eval string.
  local prompt_json
  prompt_json=$(python3 -c "import sys, json; print(json.dumps(sys.argv[1]))" "$prompt")
  echo "[grok-bridge] filling prompt (${#prompt} chars)..." >&2
  opencli browser "$SESSION" eval "(() => {
    const input = document.querySelector('$INPUT_SEL');
    if (!input) return {ok:false, why:'no input'};
    input.focus();
    // Clear existing content
    const range = document.createRange();
    range.selectNodeContents(input);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    document.execCommand('delete');
    // Insert text — fires beforeinput → ProseMirror updates state
    document.execCommand('insertText', false, ${prompt_json});
    return {ok:true, text_now: input.innerText.slice(0, 60)};
  })()" 2>&1 | grep -E '"ok"|"text_now"' | head -2

  sleep 1

  # 3. Wait for the submit button to appear (it only renders after input has content).
  echo "[grok-bridge] waiting for submit button..." >&2
  opencli browser "$SESSION" wait selector "$SUBMIT_SEL" --timeout 10 >/dev/null 2>&1 || \
    die "submit button never appeared. Input may not have registered text properly." 1

  # 4. Click submit
  echo "[grok-bridge] clicking 提交..." >&2
  opencli browser "$SESSION" click "$SUBMIT_SEL" 2>&1 | tail -2

  # 5. Wait for URL to transition to /c/<uuid> — that's the send-completed signal.
  echo "[grok-bridge] waiting for /c/ navigation (send-completed signal)..." >&2
  local sent=0
  for i in $(seq 1 30); do
    sleep 1
    local url
    url=$(opencli browser "$SESSION" eval "location.href" 2>/dev/null | tail -3 | grep -oE 'https?://[^"]+' | head -1)
    if [[ "$url" == *"/c/"* ]]; then
      sent=1
      echo "[grok-bridge]   ✓ sent — now on $url" >&2
      break
    fi
  done
  [ "$sent" = "0" ] && die "send button clicked but URL didn't transition to /c/<uuid>" 1

  # 6. Poll for response stable (idle detection by text length).
  echo "[grok-bridge] waiting for response (timeout ${TIMEOUT_SEC}s, idle ${IDLE_SEC}s)..." >&2
  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_size=0 last_change=$SECONDS first_seen=0
  while [ $SECONDS -lt $deadline ]; do
    sleep 1
    local cur
    cur=$(opencli browser "$SESSION" extract --chunk-size 50000 2>/dev/null > "$OUT_DIR/poll-$ts.md" && wc -c < "$OUT_DIR/poll-$ts.md" | xargs)
    cur=${cur:-0}
    if [ "$cur" -gt "$last_size" ] && [ "$first_seen" = "0" ]; then
      first_seen=1
    fi
    if [ "$cur" != "$last_size" ]; then
      last_size=$cur
      last_change=$SECONDS
    elif [ "$first_seen" = "1" ] && [ $((SECONDS - last_change)) -ge "$IDLE_SEC" ]; then
      break
    fi
  done

  # 7. Final extract
  opencli browser "$SESSION" extract --chunk-size 50000 > "$response_file" 2>/dev/null || \
    die "final extract failed" 1

  echo "RESPONSE_FILE=$response_file"
  echo "---"
  cat "$response_file"
  extract_callbacks "$response_file" "grok"
  rm -f "$OUT_DIR/poll-$ts.md"
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
  delete_banner "grok" "delete conversation via UI click" "${DELETE_ID:-ALL}"
  if [ "$DELETE_DRY_RUN" = "1" ]; then return 0; fi
  echo "[grok:delete] NOT IMPLEMENTED — selector for trash icon unknown." >&2
  echo "  Workaround: hover conversation in sidebar → trash icon." >&2
  exit 1
}

parse_opts() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
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
  status)  cmd_status ;;
  bind)    cmd_bind ;;
  list)    cmd_list ;;
  modes)   cmd_modes ;;
  delete)  shift; cmd_delete "$@" ;;
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
  *) die "unknown command: $CMD (try: status / bind / list / modes / ask / review / delete)" 2 ;;
esac
