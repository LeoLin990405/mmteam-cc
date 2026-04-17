# Migration Guide — from ~/bin/mmteam to mmteam-cc plugin

If you previously used mmteam as loose scripts in `~/bin/`, this guide helps you transition to the packaged plugin.

## What changes

| Before | After |
|---|---|
| Scripts in `~/bin/mmteam*` (manual) | Vendored in repo `bin/`, installed to `~/.local/bin/` via `install.sh` |
| MCP registered by hand in `~/.claude.json` | `register-mcp.mjs` handles idempotently |
| SKILL.md in `~/.claude/skills/mmteam/` | Now at `plugins/mmteam/skills/mmteam/` (plugin-bundled) |
| No slash commands | 13 `/mmteam:*` commands available after plugin install |
| No agent | `mmteam-orchestrator` agent auto-routes tasks |

## What stays the same

- Team data in `~/.claude/teams/<team>/` — unchanged
- A2A protocol wire format — unchanged
- All CLI subcommands (`mmteam a2a send`, `mmteam a2a fanout`, etc.) — unchanged
- Existing teams keep working without recreation

## Steps

1. **Clone the repo**
   ```bash
   git clone https://github.com/LeoLin990405/mmteam-cc.git ~/Projects/mmteam-cc
   ```

2. **Run install.sh**
   ```bash
   cd ~/Projects/mmteam-cc
   bash install.sh --force   # overwrites ~/bin/ copies with vendored versions
   ```

3. **Install the plugin**
   ```
   /plugin marketplace add LeoLin990405/mmteam-cc
   /plugin install mmteam@mmteam-cc
   /reload-plugins
   ```

4. **Restart Claude Code** — MCP tools activate

5. **Verify**
   ```bash
   bash doctor.sh
   /mmteam:status <your-existing-team>
   ```

## Rollback

```bash
bash uninstall.sh
# Restore your old ~/bin/mmteam* if needed
```

## Keeping in sync

If you continue iterating on `~/bin/mmteam*` locally:
```bash
cd ~/Projects/mmteam-cc
bash scripts/sync-from-dev.sh   # copies ~/bin/mmteam* → repo bin/
git diff bin/                    # review
git commit -am "sync: mmteam v2.X snapshot"
```
