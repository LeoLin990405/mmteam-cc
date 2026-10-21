#!/usr/bin/env bash
# codex-launch-with-cdp.sh — Relaunch Codex Desktop App with CDP port 9238.
#
# opencli codex hardcodes CDP port 9238, but Codex Desktop App by default does
# NOT enable remote debugging. This script kills the running Codex.app and
# relaunches it with --remote-debugging-port=9238 so opencli can drive the App.
#
# Mirror of antigravity-launch-with-cdp.sh / trae-solo-launch-with-cdp.sh.
#
# WARNING: Kills the currently running Codex.app — all open conversations stay
# (persisted by Codex) but any in-flight streaming will be interrupted. Save /
# wait for current task to finish before running.
#
# Usage:
#   codex-launch-with-cdp.sh              # default: port 9238, background
#   codex-launch-with-cdp.sh --port 9238 [--bg]
#   codex-launch-with-cdp.sh --fg         # foreground (block terminal)
#
# After this script:
#   curl -s http://localhost:9238/json/version | head
#   ~/.claude/bin/codex-bridge.sh status   # should show Connected

set -euo pipefail

PORT=9238
BG=1   # default background (don't block terminal)

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --bg)   BG=1; shift ;;
    --fg)   BG=0; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "[codex-launch] unknown arg: $1" >&2; exit 2 ;;
  esac
done

APP="/Applications/Codex.app"
BIN="$APP/Contents/MacOS/Codex"

if [ ! -x "$BIN" ]; then
  echo "[codex-launch] Codex Desktop App not found at $APP" >&2
  exit 1
fi

# Step 1: quit running Codex gracefully, then force-kill stragglers.
echo "[codex-launch] quitting existing Codex..."
osascript -e 'tell application "Codex" to quit' 2>/dev/null || true
sleep 2
pkill -f "/Applications/Codex.app/Contents/" 2>/dev/null || true
sleep 1

# Step 2: launch with CDP flag
echo "[codex-launch] launching with --remote-debugging-port=$PORT..."
if [ "$BG" = "1" ]; then
  nohup "$BIN" --remote-debugging-port="$PORT" >/dev/null 2>&1 &
  disown
  echo "[codex-launch] launched in background (pid $!)."
else
  "$BIN" --remote-debugging-port="$PORT" >/dev/null 2>&1 &
  echo "[codex-launch] launched (pid $!). Returning to shell."
fi

# Step 3: poll for CDP readiness
echo "[codex-launch] waiting up to 30s for CDP on port $PORT..."
for i in $(seq 1 30); do
  if curl -s --max-time 1 "http://localhost:$PORT/json/version" | grep -q "Browser" 2>/dev/null; then
    echo "[codex-launch] ✓ CDP up on port $PORT after ${i}s"
    echo
    echo "Verify:"
    echo "  curl -s http://localhost:$PORT/json/version | head"
    echo "  ~/.claude/bin/codex-bridge.sh status"
    exit 0
  fi
  sleep 1
done

echo "[codex-launch] ✗ CDP did NOT come up on port $PORT after 30s" >&2
echo "  Check: pgrep -lf 'Codex.app/Contents/MacOS'" >&2
echo "  Possible: Codex App ignored the --remote-debugging-port flag." >&2
exit 1
