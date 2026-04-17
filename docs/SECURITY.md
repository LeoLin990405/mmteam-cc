# Security Considerations

## Bearer tokens

Each team generates a random bearer token on creation, stored in:
- `~/.claude/teams/<team>/config.json`
- `~/.claude/teams/<team>/a2a-registry.json`

These files are `chmod 600` (owner-only read/write). Tokens are UUID4 — cryptographically random, not guessable.

**Rotation**: delete the team and recreate to generate a new token. There is no hot-rotation mechanism.

## Network exposure

A2A daemons bind to `127.0.0.1` by default — only reachable from localhost.

For cross-host use, daemons bind `0.0.0.0`. In this case:
- Use a trusted network (LAN, Tailscale, VPN)
- Or put HTTPS reverse proxy in front (nginx, caddy)
- There is no built-in TLS/mTLS

## ~/.claude.json modification

`install.sh` and `register-mcp.mjs` modify `~/.claude.json` to register the MCP server.

Safety measures:
- Always creates `~/.claude.json.bak-<timestamp>` before any write
- Idempotent — re-running doesn't duplicate entries
- `uninstall.sh` cleanly removes the `mcpServers.mmteam` key

## Permission model

Slash commands run with `context: fork` — they execute in a forked context with the specified allowed tools. The `mmteam-bridge.mjs` wrapper only invokes the `mmteam` binary — it does not read or modify source code.

The `mmteam-orchestrator` agent has `tools: Bash` — it can execute shell commands. This is necessary to invoke the mmteam CLI but means it operates with the user's shell permissions.

## Teammate isolation

Each teammate runs as a separate subprocess with its own environment. They do not share memory or state beyond the team's `tasks.json` file.

CC clone teammates (`kimi-code` etc.) run in isolated HOME directories (`~/.claude-envs/<slug>/`), so their Claude settings and session data don't cross-contaminate.

## API keys

mmteam does NOT store or manage API keys. Each CC clone has its own API key configured in its launcher script (`~/bin/<slug>-code`). mmteam just invokes the binary — it never sees the key.

## Recommendations

1. Don't commit `~/.claude/teams/` to version control (contains bearer tokens)
2. For cross-host use, prefer Tailscale over raw internet exposure
3. Run `doctor.sh` periodically to verify configuration integrity
4. Use `uninstall.sh` for clean removal — don't manually delete files
