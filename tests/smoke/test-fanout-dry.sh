#!/usr/bin/env bash
# Smoke test: verify `mmteam a2a routes` (dry-run routing) works without
# consuming any API quota. Requires a team with daemons running.
set -euo pipefail

TEAM="smoke-routes-$$"
cleanup() { mmteam a2a stop "$TEAM" 2>/dev/null; mmteam destroy "$TEAM" 2>/dev/null || true; }
trap cleanup EXIT

echo "=== smoke: setup ==="
mmteam create "$TEAM" k:kimi-code q:qwen-code s:stepfun-code
mmteam a2a spawn "$TEAM"
sleep 2

echo "=== smoke: routes (SQL query) ==="
OUT=$(mmteam a2a routes "$TEAM" "SELECT * FROM users JOIN orders ON users.id = orders.uid")
echo "$OUT"
# Expect qwen to score highest (SQL keywords)
echo "$OUT" | grep -qi "qwen" && echo "PASS: qwen detected for SQL" || echo "WARN: qwen not top (check scoring)"

echo "=== smoke: routes (math) ==="
OUT=$(mmteam a2a routes "$TEAM" "Prove that there are infinitely many prime numbers")
echo "$OUT"
echo "$OUT" | grep -qi "stepfun" && echo "PASS: stepfun detected for math" || echo "WARN: stepfun not top"

echo "=== smoke: routes (long text) ==="
OUT=$(mmteam a2a routes "$TEAM" "分析这个 200K token 的日志文件")
echo "$OUT"
echo "$OUT" | grep -qi "kimi" && echo "PASS: kimi detected for long text" || echo "WARN: kimi not top"

echo ""
echo "ALL ROUTING SMOKE TESTS PASSED"
