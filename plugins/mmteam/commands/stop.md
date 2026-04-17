---
description: Stop all A2A daemons for a team and close its cmux workspace
argument-hint: '<team-name>'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

SIGTERM all A2A HTTP daemons registered for `<team-name>`, then close the team's cmux workspace (if dock mode was used). Registry and task history are preserved — use `/mmteam:destroy` for full cleanup.

Remote teammates (`kind=remote` in registry) are NOT stopped — they live on another host.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" stop $ARGUMENTS`
