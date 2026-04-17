---
description: Fully delete a team (daemons + registry + tasks + artifacts)
argument-hint: '<team-name>'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Destructive: stops all daemons AND removes `~/.claude/teams/<team-name>/` entirely. Task history, artifacts, and registry are lost.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" destroy $ARGUMENTS`

Remote teammates registered in this team's registry are not affected on their host — this only wipes the local view.
