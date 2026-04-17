# Example: MCP-Native Usage (No Slash Commands)

After installation, Claude Code can call mmteam tools directly during conversation.

## Available MCP tools

After `install.sh` + CC restart, these tools are available natively:

```
mcp__mmteam__a2a_list_teams    — list all teams
mcp__mmteam__a2a_spawn         — start daemons
mcp__mmteam__a2a_stop          — stop daemons
mcp__mmteam__a2a_ls            — list registry
mcp__mmteam__a2a_card          — get Agent Card
mcp__mmteam__a2a_send          — dispatch task (blocking)
mcp__mmteam__a2a_get           — check task status
mcp__mmteam__a2a_cancel        — cancel running task
mcp__mmteam__a2a_ask           — smart-routed dispatch
mcp__mmteam__a2a_fanout        — parallel broadcast
mcp__mmteam__a2a_pipeline      — write→review→synth
mcp__mmteam__a2a_watch         — open dashboard
mcp__mmteam__a2a_unwatch       — close dashboard
mcp__mmteam__a2a_quota         — check teammate quotas
mcp__mmteam__a2a_routes        — preview routing
mcp__mmteam__a2a_who           — one-line team status
mcp__mmteam__a2a_cost          — cost report
mcp__mmteam__a2a_register_remote — add remote teammate
mcp__mmteam__a2a_discover      — probe remote Agent Card
```

## Conversation example

```
User: 帮我并行问 kimi 和 gemini "什么是 BASE 原理"，然后总结差异

Claude:
  [calls mcp__mmteam__a2a_send({team:"bq", agent:"kimi", text:"什么是 BASE 原理"})]
  [calls mcp__mmteam__a2a_send({team:"bq", agent:"gem", text:"什么是 BASE 原理"})]
  [synthesizes difference analysis from both responses]
```

Claude autonomously decides to use the MCP tools — no slash command invocation needed. The mmteam-orchestrator agent can also be triggered to make framework-level decisions.

## Verifying MCP registration

```bash
# Check if registered
node plugins/mmteam/scripts/register-mcp.mjs --status

# Or directly
jq '.mcpServers.mmteam' ~/.claude.json
```
