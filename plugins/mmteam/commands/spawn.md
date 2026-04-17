---
description: Start A2A HTTP daemons for all teammates in a team
argument-hint: '<team-name> [--dock] [--monitor] [--port <N>]'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Spawn one HTTP daemon per teammate. Each exposes A2A v0.3 at its own port with a team-level bearer token.

Modes:
- **headless** (default) — fastest, background subprocesses. No visible CLI TUI.
- **--dock** — open a dedicated cmux workspace `<team>-a2a` with one pane per teammate running the live CLI.
- **--dock --monitor** — adds a top event-stream strip showing task state transitions across all teammates.
- **--port <N>** — starting port for daemon allocation (default 55700).

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" spawn $ARGUMENTS`

After spawn, `~/.claude/teams/<team>/a2a-registry.json` lists each teammate's URL + bearer token.
