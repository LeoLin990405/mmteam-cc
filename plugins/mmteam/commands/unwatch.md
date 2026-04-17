---
description: Close the watch dashboard cmux workspace
argument-hint: '<team-name>'
context: fork
allowed-tools: Bash(node:*, mmteam:*, cmux:*)
---

Clean up the `<team>-watch` cmux workspace and delete its workspace record. Does NOT affect running A2A daemons or the team's dock workspace.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" unwatch $ARGUMENTS`
