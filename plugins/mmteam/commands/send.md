---
description: Send a task to a specific named teammate
argument-hint: '<team-name> <agent-id> "<prompt>" [--session <sid>]'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Dispatch a prompt to one named teammate via A2A `message/send` (blocking) and return the final artifact.

- `<agent-id>` must match a registered teammate in `a2a-registry.json`.
- `--session <sid>` enables multi-turn context — the server auto-rehydrates history (up to 20 turns) for the same SID.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" send $ARGUMENTS`

For automatic best-teammate selection, use `/mmteam:ask` instead.
