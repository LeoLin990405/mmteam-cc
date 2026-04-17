---
description: Bootstrap mmteam binaries and MCP registration (first-run installer)
argument-hint: ''
context: fork
allowed-tools: Bash(bash:*, node:*)
---

Run the one-shot installer. Five phases:

1. **Preflight** — detect OS, shell, $HOME, $PATH writable dirs
2. **Deps check** — require python3 ≥3.9; optional: cmux, jq, 7 CC launchers
3. **Bin install** — copy `bin/mmteam*` into `~/.local/bin/` (or `~/bin/` if requested)
4. **MCP register** — patch `~/.claude.json` to register `mcpServers.mmteam` (backs up first)
5. **Smoke test** — verify `mmteam --version` works and the MCP server self-checks

After completion, **restart Claude Code** to activate the `mcp__mmteam__a2a_*` tools. Re-run `/mmteam:setup` at any time — it's idempotent.

Run: `bash "${CLAUDE_PLUGIN_ROOT}/../../install.sh"`

To diagnose issues without reinstalling, run `bash "${CLAUDE_PLUGIN_ROOT}/../../doctor.sh"`.
