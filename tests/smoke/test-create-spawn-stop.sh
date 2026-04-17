#!/usr/bin/env bash
# Smoke test: create → spawn → status → stop → destroy lifecycle.
# Requires: mmteam on PATH, python3. Does NOT require live API keys
# (the daemon starts but any task would fail without keys — that's OK for smoke).
set -euo pipefail

TEAM="smoke-test-$$"
cleanup() { mmteam destroy "$TEAM" 2>/dev/null || true; }
trap cleanup EXIT

echo "=== smoke: create ==="
mmteam create "$TEAM" a1:kimi-code a2:glm-code
test -f "$HOME/.claude/teams/$TEAM/config.json"
echo "PASS: team created"

echo "=== smoke: spawn ==="
mmteam a2a spawn "$TEAM"
sleep 2
test -f "$HOME/.claude/teams/$TEAM/a2a-registry.json"
echo "PASS: registry exists"

echo "=== smoke: ls ==="
mmteam a2a ls "$TEAM"
echo "PASS: ls ran"

echo "=== smoke: stop ==="
mmteam a2a stop "$TEAM"
echo "PASS: stopped"

echo "=== smoke: destroy ==="
mmteam destroy "$TEAM"
test ! -d "$HOME/.claude/teams/$TEAM"
echo "PASS: destroyed"

echo ""
echo "ALL SMOKE TESTS PASSED"
