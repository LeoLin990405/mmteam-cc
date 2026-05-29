#!/usr/bin/env bash
# antigravity-launch-with-cdp.sh — Relaunch Antigravity with CDP port 9234.
#
# opencli antigravity adapter hardcodes CDP port 9234, but Antigravity by default
# does NOT enable remote debugging. This script kills the running Antigravity
# instance and relaunches it with --remote-debugging-port=9234 so opencli can
# reverse-control it.
#
# WARNING: kills the currently running Antigravity process. Any unsaved chat /
# context in Antigravity will be lost. Save before running.
#
# Usage:
#   antigravity-launch-with-cdp.sh           # default: port 9234, foreground
#   antigravity-launch-with-cdp.sh --bg      # detach (release terminal)
#   antigravity-launch-with-cdp.sh --port 9333 [--bg]
#
# After this script succeeds, verify:
#   curl -s http://localhost:9234/json/version | head
#   opencli antigravity status

set -euo pipefail

PORT=9234
BG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --bg)   BG=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "[antigravity-launch] unknown arg: $1" >&2; exit 2 ;;
  esac
done

APP="/Applications/Antigravity.app"
BIN="$APP/Contents/MacOS/Antigravity"

if [ ! -x "$BIN" ]; then
  echo "[antigravity-launch] Antigravity not found at $APP" >&2
  exit 1
fi

# Step 1: quit running Antigravity gracefully, then force-kill stragglers.
echo "[antigravity-launch] quitting existing Antigravity..."
osascript -e 'tell application "Antigravity" to quit' 2>/dev/null || true
sleep 2
# Force kill any leftover Antigravity processes
pkill -f "/Applications/Antigravity.app/Contents/MacOS/Antigravity" 2>/dev/null || true
sleep 1

# Step 2: launch with CDP flag
echo "[antigravity-launch] launching with --remote-debugging-port=$PORT..."
if [ "$BG" = "1" ]; then
  nohup "$BIN" --remote-debugging-port="$PORT" >/dev/null 2>&1 &
  disown
  echo "[antigravity-launch] launched in background (pid $!)."
else
  # Foreground but detach from terminal session
  "$BIN" --remote-debugging-port="$PORT" >/dev/null 2>&1 &
  echo "[antigravity-launch] launched (pid $!). Returning to shell."
fi

# Step 3: poll for CDP readiness
echo "[antigravity-launch] waiting up to 30s for CDP on port $PORT..."
for i in $(seq 1 30); do
  if curl -s --max-time 1 "http://localhost:$PORT/json/version" | grep -q "Browser" 2>/dev/null; then
    echo "[antigravity-launch] ✓ CDP up on port $PORT after ${i}s"
    echo
    echo "Verify with:"
    echo "  curl -s http://localhost:$PORT/json/version | head"
    echo "  opencli antigravity status"
    exit 0
  fi
  sleep 1
done

echo "[antigravity-launch] ✗ CDP did NOT come up on port $PORT after 30s" >&2
echo "  Check: ps aux | grep Antigravity" >&2
echo "  Possible: Antigravity ignored the --remote-debugging-port flag" >&2
exit 1
