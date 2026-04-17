---
description: Show team members, daemon liveness, and task statistics
argument-hint: '<team-name>'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

List a team's members, their A2A daemon liveness (✅ alive / ⚫ down), port, PID, and recent task counts. For per-teammate quota (5min/1h/5h/24h request counts and token totals), use `mmteam a2a quota <team>` directly.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" status $ARGUMENTS`
