#!/usr/bin/env bash
# grok-launch-with-cdp.sh — Launch a dedicated Chrome instance for Grok web with CDP.
#
# Why a dedicated instance: we DON'T want to attach to Leo's main Chrome
# (which has all his logins, tabs, sessions). Instead we spawn a separate
# Chrome with its own --user-data-dir profile, navigate to grok.com,
# expose CDP on port 9237 with --remote-allow-origins=* so our Python
# helper can ws-attach.
#
# First-time use: a Chrome window opens at grok.com. Leo logs in once.
# The session cookies persist in the dedicated profile dir.
#
# Usage:
#   grok-launch-with-cdp.sh            # foreground, opens window
#   grok-launch-with-cdp.sh --bg       # detach (release terminal)
#   grok-launch-with-cdp.sh --port 9337 --profile-dir /tmp/grok-alt

set -euo pipefail

PORT=9237
BG=0
PROFILE_DIR="$HOME/.claude/grok-chrome-profile"
URL="https://grok.com/"

while [ $# -gt 0 ]; do
  case "$1" in
    --port)        PORT="$2"; shift 2 ;;
    --bg)          BG=1; shift ;;
    --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
    --url)         URL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "[grok-launch] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Find Chrome — prefer Google Chrome, fallback to Chromium / Brave / Edge.
CHROME=""
for cand in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  ; do
  if [ -x "$cand" ]; then CHROME="$cand"; break; fi
done

if [ -z "$CHROME" ]; then
  echo "[grok-launch] no supported Chromium browser found in /Applications" >&2
  exit 1
fi

mkdir -p "$PROFILE_DIR"

# Kill any prior Chrome process using this exact profile dir (otherwise
# Chrome refuses to enable CDP and we get a silent no-op).
pkill -f "user-data-dir=$PROFILE_DIR" 2>/dev/null || true
sleep 1

echo "[grok-launch] Chrome: $CHROME"
echo "[grok-launch] profile: $PROFILE_DIR"
echo "[grok-launch] launching with --remote-debugging-port=$PORT --remote-allow-origins=*..."

ARGS=(
  "--remote-debugging-port=$PORT"
  "--remote-allow-origins=*"
  "--user-data-dir=$PROFILE_DIR"
  "--no-first-run"
  "--no-default-browser-check"
  "$URL"
)

if [ "$BG" = "1" ]; then
  nohup "$CHROME" "${ARGS[@]}" >/dev/null 2>&1 &
  disown
  echo "[grok-launch] launched in background (pid $!)."
else
  "$CHROME" "${ARGS[@]}" >/dev/null 2>&1 &
  echo "[grok-launch] launched (pid $!). Returning to shell."
fi

echo "[grok-launch] waiting up to 30s for CDP on port $PORT..."
for i in $(seq 1 30); do
  if curl -s --max-time 1 "http://localhost:$PORT/json/version" | grep -q "Browser" 2>/dev/null; then
    echo "[grok-launch] ✓ CDP up on port $PORT after ${i}s"
    echo
    echo "Verify with:"
    echo "  curl -s http://localhost:$PORT/json/version | head"
    echo "  agent-bridge grok status"
    echo
    echo "First time? Log into Grok in the opened Chrome window once;"
    echo "the dedicated profile persists cookies between sessions."
    exit 0
  fi
  sleep 1
done

echo "[grok-launch] ✗ CDP did NOT come up on port $PORT after 30s" >&2
exit 1
