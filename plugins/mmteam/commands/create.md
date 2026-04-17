---
description: Create a new multi-model team with named teammates
argument-hint: '<team-name> <agent-id>:<cli>[:<model>] [<agent-id>:<cli>[:<model>] ...]'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Create a new team registered at `~/.claude/teams/<team-name>/`.

Each teammate is specified as `<agent-id>:<cli>[:<model>]`:
- `agent-id` — short handle used in send/fanout/pipeline (e.g. `kimi`, `gem`, `gpt`)
- `cli` — one of the supported backends:
  - `kimi-code` / `glm-code` / `doubao-code` / `qwen-code` / `minimax-code` / `mimo-code` / `stepfun-code` — Chinese CC clones
  - `codex` — OpenAI Codex CLI
  - `gemini` — Google Gemini CLI
  - `claude` — Anthropic Claude CLI
  - Add `-team` suffix to any of the above to enable internal agent-teams sub-sidecars (e.g. `kimi-code-team`, `claude-team`)
- `model` — optional model override (e.g. `kimi-k2.6-code-preview`)

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" create $ARGUMENTS`

After creation, use `/mmteam:spawn <team-name>` to start the A2A HTTP daemons.
