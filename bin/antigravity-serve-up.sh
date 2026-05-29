#!/usr/bin/env bash
# antigravity-serve-up.sh — Start opencli antigravity Anthropic-API proxy daemon.
#
# Antigravity serve exposes a `/v1/messages` Anthropic-compatible endpoint that
# forwards requests to Antigravity App via CDP and returns the response
# synchronously. This is the "agent completes → sends signal back to Claude"
# layer — no polling needed; HTTP response IS the completion signal.
#
# Prerequisite: Antigravity launched with CDP 9234 (run antigravity-launch-with-cdp.sh first).
#
# Usage:
#   antigravity-serve-up.sh              # default: port 8082, timeout 600s, background
#   antigravity-serve-up.sh --port 8082 --timeout 600
#   antigravity-serve-up.sh status       # check if serve daemon is up
#   antigravity-serve-up.sh stop         # kill serve daemon
#
# After this script:
#   curl -s http://localhost:8082/v1/messages -X POST \
#     -H 'Content-Type: application/json' \
#     -d '{"model":"claude-3-5-sonnet","max_tokens":2048,
#          "messages":[{"role":"user","content":"say pong"}]}'

set -euo pipefail

ACTION="${1:-up}"
PORT=8082
TIMEOUT=600
LOG="/tmp/antigravity-serve.log"
PIDFILE="/tmp/antigravity-serve.pid"

shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --port)    PORT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "[antigravity-serve-up] unknown arg: $1" >&2; exit 2 ;;
  esac
done

is_running() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

is_listening() {
  curl -s --max-time 1 "http://localhost:$PORT/v1/messages" -X OPTIONS -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^(200|204|404|405)$'
}

case "$ACTION" in
  status)
    echo "=== Antigravity serve daemon ==="
    if is_running; then
      echo "Process: alive (pid $(cat "$PIDFILE"))"
    else
      echo "Process: not running"
    fi
    if is_listening; then
      echo "Port $PORT: listening ✓"
    else
      echo "Port $PORT: not listening"
    fi
    echo "Log: $LOG"
    tail -5 "$LOG" 2>/dev/null
    ;;
  stop)
    if is_running; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "[antigravity-serve-up] stopped"
    else
      echo "[antigravity-serve-up] not running"
    fi
    ;;
  up|"")
    if is_running; then
      echo "[antigravity-serve-up] already running (pid $(cat "$PIDFILE")). Use 'stop' first to restart."
      exit 0
    fi
    # Verify CDP first
    if ! curl -s --max-time 2 "http://localhost:9234/json/version" | grep -q "Browser"; then
      echo "[antigravity-serve-up] ✗ Antigravity CDP not on port 9234. Run antigravity-launch-with-cdp.sh first." >&2
      exit 1
    fi
    echo "[antigravity-serve-up] starting opencli antigravity serve --port $PORT --timeout $TIMEOUT ..."
    nohup opencli antigravity serve --port "$PORT" --timeout "$TIMEOUT" > "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3
    if is_listening; then
      echo "[antigravity-serve-up] ✓ listening on :$PORT (pid $(cat "$PIDFILE"))"
    else
      echo "[antigravity-serve-up] ✗ daemon launched but not listening. Check $LOG"
      tail -10 "$LOG"
      exit 1
    fi
    ;;
  *) echo "[antigravity-serve-up] unknown action: $ACTION" >&2; exit 2 ;;
esac
