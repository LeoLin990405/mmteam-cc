#!/usr/bin/env bash
# Smoke test: verify A2A HTTP endpoints respond.
# Creates a team, spawns, then curls Agent Card and health endpoint.
# Does NOT send actual tasks (would need API keys).
set -euo pipefail

TEAM="smoke-a2a-$$"
cleanup() { mmteam a2a stop "$TEAM" 2>/dev/null; mmteam destroy "$TEAM" 2>/dev/null || true; }
trap cleanup EXIT

echo "=== smoke: setup ==="
mmteam create "$TEAM" a1:kimi-code
mmteam a2a spawn "$TEAM"
sleep 2

# Extract URL from registry
URL=$(python3 -c "
import json, sys
r = json.load(open('$HOME/.claude/teams/$TEAM/a2a-registry.json'))
print(r['a1']['url'])
")

echo "=== smoke: Agent Card ==="
CARD=$(curl -sf "${URL}.well-known/agent-card.json")
echo "$CARD" | python3 -m json.tool > /dev/null
echo "PASS: Agent Card is valid JSON"

# Check required fields
echo "$CARD" | python3 -c "
import json, sys
c = json.load(sys.stdin)
assert 'name' in c, 'missing name'
assert 'skills' in c, 'missing skills'
assert 'authentication' in c, 'missing authentication'
print('PASS: Agent Card has required fields')
"

echo "=== smoke: health ==="
HEALTH=$(curl -sf "${URL}health")
echo "$HEALTH" | python3 -c "
import json, sys
h = json.load(sys.stdin)
assert h.get('status') == 'ok', f'bad status: {h}'
print('PASS: health endpoint ok')
"

echo ""
echo "ALL A2A SMOKE TESTS PASSED"
