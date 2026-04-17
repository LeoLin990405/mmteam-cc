# Changelog

## v2.0.1 (2026-04-17)

### Added
- **Brain mode** — `mmteam-orchestrator` agent gains autonomous multi-step workflow: decompose → dispatch → cross-review → retry → synthesize
- **`/mmteam:brain`** — slash command to activate brain mode (CC as project manager)
- **`/mmteam:supervise`** — slash command for CLI-driven autonomous supervisor loop
- **`mmteam a2a supervise`** — CLI subcommand with `--max-retries`, `--cost-ceiling`, `--no-review`, `--no-synth`, `--subtasks-file`, `--json`
- **Cross-review matrix** — automatic reviewer selection based on model family diversity
- **ROADMAP.md** — full iteration plan v2.1–v2.6

### Fixed
- `mmteam status` crash on A2A tasks (dict status + missing desc fields)

## v2.0.0 (2026-04-17)

**First public release** — extracts mmteam v2.18 from `~/bin/` into a standalone Claude Code plugin.

### Added
- **13 slash commands** (`/mmteam:create`, `/mmteam:spawn`, `/mmteam:ask`, `/mmteam:fanout`, `/mmteam:pipeline`, `/mmteam:watch`, `/mmteam:send`, `/mmteam:stop`, `/mmteam:destroy`, `/mmteam:status`, `/mmteam:unwatch`, `/mmteam:remote`, `/mmteam:setup`)
- **mmteam-orchestrator agent** — automatic task→framework routing (single / fanout / pipeline / -team)
- **Vendored bin/** — mmteam CLI + A2A server + monitor + MCP server (~4000 lines)
- **install.sh / uninstall.sh / doctor.sh** — full lifecycle management
- **register-mcp.mjs** — idempotent MCP registration with backup
- **marketplace.json** — Claude Code plugin marketplace compatible
- **8 `-team` variants** — claude-team + 7 CC clone families, each with internal agent-teams sidecars
- **Cross-host teammates** — `/mmteam:remote` for A2A over network
- **docs/** — MIGRATION, ARCHITECTURE, TEAMMATE-TYPES, REMOTE-TEAMMATE, CMUX-SETUP, SECURITY
- **examples/** — 7 usage recipes
- **tests/smoke/** — 4 CI-friendly smoke tests
- **.github/workflows/** — lint, python compile, smoke on ubuntu + macos

### Protocol compatibility
- Google A2A v0.3 (Agent Card, message/send, tasks/get, tasks/cancel, Bearer auth)
- MCP stdio JSON-RPC (20 tools exposed to Claude Code)

### Backward compatibility
- cn-cc plugin is **not affected** — install both side by side
- Existing `~/bin/mmteam*` scripts continue to work — the repo vendors a snapshot
