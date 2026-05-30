#!/usr/bin/env bash
# grok-bridge.sh — Drive Grok web (grok.com) via the user's main Chrome
# using opencli's official Browser Bridge (extension + daemon, port 19825).
#
# REVISION 2026-05-31: rewritten from dedicated-Chrome model to use the
# user's primary Chrome (their logged-in Google account). No more port-9237
# spawned instance. Requires the opencli Chrome extension to be loaded:
#   1. Open chrome://extensions/, enable Developer mode
#   2. "Load unpacked" → /Users/leo/Projects/OpenCLI/extension
#   3. Verify: `opencli doctor` → [OK] Extension: connected
#
# ⚠ KNOWN LIMITATION (verified 2026-05-31 on Grok free tier):
#   Grok's free tier blocks programmatic input submission at React state
#   level. The "SuperGrok upgrade" overlay is more than a DOM modal — it
#   disables the input form's submit handler even after the modal node
#   is nuked from DOM. Symptoms:
#     · attach/model/dictate buttons report disabled=true
#     · Enter / contextual-button-click both no-op (no POST fires)
#     · plain modal nuking doesn't lift the React paywall
#   Workaround: requires SuperGrok subscription, OR send via another
#   surface (Claude/ChatGPT/Gemini web with same main-Chrome architecture).
#   Status / list / bind / login flow all work — only ASK is blocked.
#
# Session name "grok" is the opencli browser-session alias bound to a
# specific Chrome tab. Bind happens lazily on first `ask` call.
#
# Usage:
#   grok-bridge.sh status                          # opencli doctor + ping daemon
#   grok-bridge.sh list                            # state of bound tab (interactive refs)
#   grok-bridge.sh modes                           # Grok model picker (informational)
#   grok-bridge.sh ask    <prompt>     [--timeout S] [--idle SEC]
#   grok-bridge.sh review <prompt-file> [--timeout S]
#   grok-bridge.sh bind                            # explicit bind active tab to "grok"

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

INPUT_SEL='textarea[placeholder="Ask me anything..."]'
# Fallback selectors tried in order if INPUT_SEL misses.
INPUT_FALLBACKS=(
  'textarea[aria-label="Ask Grok anything"]'
  'textarea[placeholder="What do you want to know?"]'
  'textarea[placeholder*="Ask"]'
  'textarea[placeholder*="message"]'
)

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
  probe=$(opencli browser "$SESSION" eval "(() => ({url: location.href, title: document.title, logged_in_signal: !document.querySelector('button:has-text(\"登录\")') && !!document.querySelector('textarea')}))()" 2>/dev/null | tail -10)
  if [ -n "$probe" ]; then
    echo "$probe"
  else
    echo "  ✗ session '$SESSION' not bound yet — run 'grok-bridge.sh bind' (with grok.com tab active)"
  fi
}

cmd_bind() {
  check_extension
  echo "[grok-bridge] binding active Chrome tab to session '$SESSION'..." >&2
  opencli browser "$SESSION" bind 2>&1 | head -5
  echo
  echo "Verify with:"
  echo "  opencli browser $SESSION state"
}

cmd_modes() {
  python3 <<'PYEOF'
import json
print(json.dumps({
    "surface": "grok",
    "axis": "model",
    "active_mode": "(set in Grok UI model picker)",
    "available_modes": ["grok-2", "grok-3", "grok-3-think", "grok-4", "grok-4-heavy"],
    "note": "Grok's model is chosen via the in-page picker; not programmatic."
}, indent=2))
PYEOF
}

cmd_list() {
  check_extension
  # Use eval — 'state' default format isn't pure JSON.
  local raw
  raw=$(opencli browser "$SESSION" eval "(() => {
    const all_ta = document.querySelectorAll('textarea');
    return {
      url: location.href,
      title: document.title,
      total_textareas: all_ta.length,
      logged_in_signal: location.href.includes('grok.com') && !document.body.innerText.includes('登录') && !document.body.innerText.includes('Sign in'),
      conv_links: Array.from(document.querySelectorAll('a[href*=\"/chat/\"], a[href*=\"/c/\"]')).slice(0, 10).map(a => ({href: a.getAttribute('href'), text: (a.textContent||'').trim().slice(0, 50)})),
    };
  })()" 2>/dev/null)
  python3 -c "
import json, re, sys
raw = '''$raw'''
# opencli eval output may be a JSON-like literal at the end; extract last {...} block
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
    'logged_in': bool(inner.get('logged_in_signal')),
    'total_textareas': inner.get('total_textareas', 0),
    'conv_links': inner.get('conv_links', []),
    'sessions': [{'id': 'current', 'title': inner.get('title', '(grok page)')[:60]}],
    'note': 'main Chrome via opencli extension'
}, indent=2, ensure_ascii=False))
"
}

# Ensure the bound tab is at grok.com (open if not).
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

  # 1. Make sure we're on grok.com
  _ensure_grok_page

  # 2. Wait for the chat input to appear
  echo "[grok-bridge] waiting for chat input..." >&2
  opencli browser "$SESSION" wait selector "$INPUT_SEL" --timeout 15 >/dev/null 2>&1 || \
    die "chat input never appeared. Are you logged in?" 1

  # 3. Capture baseline state to detect new assistant reply later.
  local baseline
  baseline=$(opencli browser "$SESSION" extract -f md 2>/dev/null | wc -c | xargs)

  # 4. Fill input
  echo "[grok-bridge] filling prompt (${#prompt} chars)..." >&2
  opencli browser "$SESSION" fill "$INPUT_SEL" "$prompt" 2>&1 | tail -3

  # 5. Click send — Grok's send button is the LAST button in the form.
  #    Use JS eval since the button has no aria-label / type=submit.
  echo "[grok-bridge] clicking send..." >&2
  opencli browser "$SESSION" eval "(() => {
    const ta = document.querySelector('$INPUT_SEL');
    const form = ta?.closest('form') || ta?.parentElement?.parentElement;
    const btns = form ? Array.from(form.querySelectorAll('button')).filter(b => !b.disabled) : [];
    const target = btns[btns.length - 1];
    if (!target) return {ok: false, why: 'no send button'};
    target.click();
    return {ok: true, btn_cls: (target.className||'').slice(0,60)};
  })()" 2>&1 | tail -5

  # 6. Poll for response stable (idle detection).
  echo "[grok-bridge] waiting for response (timeout ${TIMEOUT_SEC}s, idle ${IDLE_SEC}s)..." >&2
  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_size=0 last_change=$SECONDS first_seen=0
  while [ $SECONDS -lt $deadline ]; do
    sleep 1
    local cur
    cur=$(opencli browser "$SESSION" extract -f md 2>/dev/null > "$OUT_DIR/poll-$ts.md" && wc -c < "$OUT_DIR/poll-$ts.md" | xargs)
    cur=${cur:-0}
    if [ "$cur" -gt "$baseline" ] && [ "$first_seen" = "0" ]; then
      first_seen=1
      echo "[grok-bridge]   response started ($cur chars)..." >&2
    fi
    if [ "$cur" != "$last_size" ]; then
      last_size=$cur
      last_change=$SECONDS
    elif [ "$first_seen" = "1" ] && [ $((SECONDS - last_change)) -ge "$IDLE_SEC" ]; then
      break
    fi
  done

  # 7. Final extract = response file.
  opencli browser "$SESSION" extract -f md > "$response_file" 2>/dev/null || \
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
  echo "  Use discover-delete-selector.sh while hovering to find the selector." >&2
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
