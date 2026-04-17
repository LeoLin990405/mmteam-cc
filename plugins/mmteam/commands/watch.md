---
description: Open a multi-window cmux dashboard tailing every teammate's live output
argument-hint: '<team-name>'
context: fork
allowed-tools: Bash(node:*, mmteam:*, cmux:*)
---

Open a new cmux workspace `<team>-watch` with:
- **Top strip** — `mmteam-a2a-monitor.py` printing colored task state transitions (submit / working / completed / canceled / failed) across all teammates in chronological order
- **Grid below** — one pane per teammate running `mmteam a2a follow` (colored `tail -F` of the daemon log showing streamed stdout)

Works with any spawn mode (headless or dock). You can have both `<team>-a2a` (dock) and `<team>-watch` (observability) workspaces open simultaneously.

Limit: ≤6 teammates (grid layout constraint). For larger teams, use `--agents` to filter.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" watch $ARGUMENTS`

Close with `/mmteam:unwatch <team>`. Requires cmux installed — see docs/CMUX-SETUP.md.
