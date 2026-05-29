#!/usr/bin/env bash
# trae-solo-launch-with-cdp.sh — Relaunch TRAE SOLO with CDP port 9235.
#
# Trae SOLO (com.trae.solo.app, Electron 0.1.14) does NOT enable remote
# debugging by default. This script kills the running instance and relaunches
# it with --remote-debugging-port=9235 so opencli's generic `browser` command
# can attach via CDP and drive the chat UI for Claude's /five-agents pipeline.
#
# Port 9235 chosen to avoid collision with:
#   - 9234 (antigravity, opencli hardcoded)
#   - 9222 (opencli default, also used by Antigravity Browser Control)
#   - 9333 (Antigravity default per Google docs)
#
# WARNING: Kills the currently running Trae SOLO process. Save anything you
# care about in Trae SOLO before running.
#
# Usage:
#   trae-solo-launch-with-cdp.sh                  # default: port 9235, foreground
#   trae-solo-launch-with-cdp.sh --bg             # detach (release terminal)
#   trae-solo-launch-with-cdp.sh --port 9335 [--bg]
#
# After this script succeeds, verify:
#   curl -s http://localhost:9235/json/version | head
#   ~/.claude/bin/trae-solo-bridge.sh status   (once bridge is written)

set -euo pipefail

PORT=9235
BG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --bg)   BG=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "[trae-solo-launch] unknown arg: $1" >&2; exit 2 ;;
  esac
done

APP="/Applications/TRAE SOLO.app"
BIN="$APP/Contents/MacOS/Electron"

if [ ! -x "$BIN" ]; then
  echo "[trae-solo-launch] TRAE SOLO not found at $APP" >&2
  exit 1
fi

# Step 1: quit running TRAE SOLO gracefully, then force-kill stragglers.
echo "[trae-solo-launch] quitting existing TRAE SOLO..."
osascript -e 'tell application "TRAE SOLO" to quit' 2>/dev/null || true
sleep 2
# Force kill any leftover TRAE SOLO processes (Electron + helpers + language_server)
pkill -f "/Applications/TRAE SOLO.app/Contents/" 2>/dev/null || true
sleep 1

# Step 2: launch with CDP flag (the Electron binary inside TRAE SOLO.app
# is named "Electron"; bundle identifier handles app branding)
echo "[trae-solo-launch] launching with --remote-debugging-port=$PORT..."
if [ "$BG" = "1" ]; then
  nohup "$BIN" --remote-debugging-port="$PORT" >/dev/null 2>&1 &
  disown
  echo "[trae-solo-launch] launched in background (pid $!)."
else
  "$BIN" --remote-debugging-port="$PORT" >/dev/null 2>&1 &
  echo "[trae-solo-launch] launched (pid $!). Returning to shell."
fi

# Step 3: poll for CDP readiness
echo "[trae-solo-launch] waiting up to 30s for CDP on port $PORT..."
for i in $(seq 1 30); do
  if curl -s --max-time 1 "http://localhost:$PORT/json/version" | grep -q "Browser" 2>/dev/null; then
    echo "[trae-solo-launch] ✓ CDP up on port $PORT after ${i}s"
    echo
    echo "Verify with:"
    echo "  curl -s http://localhost:$PORT/json/version | head"
    echo "  curl -s http://localhost:$PORT/json/list | python3 -m json.tool | head"
    echo
    echo "Next step (Leo):"
    echo "  1. Open chat panel in TRAE SOLO"
    echo "  2. Cmd+Shift+I to open DevTools"
    echo "  3. Inspector: find selectors for"
    echo "     - chat input (textarea or contenteditable div)"
    echo "     - send button"
    echo "     - response container (where AI text appears)"
    echo "  4. Note the 'AI generating' DOM signal (spinner class? streaming attr? button disabled?)"
    echo "  5. Paste the 3 selectors + signal to Claude"
    exit 0
  fi
  sleep 1
done

echo "[trae-solo-launch] ✗ CDP did NOT come up on port $PORT after 30s" >&2
echo "  Check: ps aux | grep -i 'TRAE SOLO'" >&2
echo "  Possible: TRAE SOLO ignored the --remote-debugging-port flag, or" >&2
echo "           ai-agent module on port 40005 is interfering with CDP." >&2
exit 1
