# Architecture

## Overview

mmteam-cc has three layers:

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Plugin Interface (Claude Code)                 │
│    /mmteam:* slash commands → mmteam-bridge.mjs          │
│    mcp__mmteam__a2a_* tools → mmteam-mcp.py              │
│    mmteam-orchestrator agent (auto-routing)               │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────────────────┐
│  Layer 2: Orchestration Engine (bin/mmteam CLI)          │
│    Team lifecycle: create / spawn / stop / destroy        │
│    Task dispatch: send / ask / fanout / pipeline          │
│    Observability: watch / follow / quota / routes / who   │
│    Consensus: Jaccard similarity + CJK bigram + judge     │
└─────────────────────┬───────────────────────────────────┘
                      │  JSON-RPC 2.0 / HTTP / Bearer
┌─────────────────────┴───────────────────────────────────┐
│  Layer 3: Per-Teammate A2A Daemons                       │
│    bin/mmteam-a2a-server.py × N (one per teammate)       │
│    Backend: HeadlessBackend | CmuxDockBackend             │
│    Protocol: Agent Card + message/send + tasks/*          │
│    Invokes real CLI (kimi-code, codex, gemini, etc.)     │
└─────────────────────────────────────────────────────────┘
```

## A2A v0.3 protocol subset

| Primitive | Endpoint | Auth |
|---|---|---|
| Agent Card | `GET /.well-known/agent-card.json` | Public |
| message/send | `POST /` JSON-RPC | Bearer |
| tasks/get | `POST /` JSON-RPC | Bearer |
| tasks/cancel | `POST /` JSON-RPC | Bearer |
| health | `GET /health` | Public |

**State machine**: `submitted → working → completed / failed / canceled`

Cancel race guard: `tasks/cancel` writes `canceled` + adds to `CANCELED` set before signaling subprocess. `message/send` checks the set in `finally` to avoid overwriting.

## Backend abstraction

### HeadlessBackend (default)
- Forks a subprocess per task (`<cli> -p <prompt>`)
- Fastest startup (<1s), no visual
- Cancel: SIGTERM → 15s → SIGKILL

### CmuxDockBackend (`--dock`)
- Creates a cmux workspace with 1-6 panes (auto-grid layout)
- CLI TUI runs persistently; tasks are sent as keystrokes
- Artifact extraction via session log tail (not scrollback)
- Cancel: sends Escape keypress to pane

## -team variants

When `cli` ends with `-team`, the server:
1. Strips `-team` to get the base CLI
2. Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
3. Wraps the prompt with TeamCreate instructions
4. The base CLI spawns 2-3 same-family sidecars, distributes subtasks, and synthesizes

This enables "multi-perspective reasoning within a single family" without consuming cross-family quota.

## MCP bridge

`mmteam-mcp.py` runs as a stdio JSON-RPC server, registered in `~/.claude.json` under `mcpServers.mmteam`. It exposes 20+ tools that map 1:1 to `mmteam a2a <verb>` subcommands.

Claude Code calls these tools natively during conversation — no slash command needed.

## Data model

All persistent state lives in `~/.claude/teams/<team>/`:

```
config.json              # member specs + team-level bearer token
tasks.json               # {tasks: [{id, status, history, artifacts}]}
a2a-registry.json        # {agent: {url, bearer_token, kind: local|remote}}
a2a-workspace.json       # cmux workspace ref (dock mode)
agent-cards/<agent>.json # startup snapshot of Agent Card
<agent>.a2a.pid/.log     # daemon PID + log
results/<tid>-<agent>.md # artifact on disk
```
