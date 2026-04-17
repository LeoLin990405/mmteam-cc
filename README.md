# mmteam-cc

> Multi-Model Agent Teams for Claude Code — orchestrate 10 AI CLIs via Google A2A v0.3 + MCP bridge.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.0-green.svg)](CHANGELOG.md)
[![A2A](https://img.shields.io/badge/protocol-A2A%20v0.3-orange.svg)](https://a2a-protocol.org)
[![MCP](https://img.shields.io/badge/protocol-MCP-purple.svg)](https://spec.modelcontextprotocol.io)

---

## What is this?

A Claude Code plugin that lets you **build teams of AI CLIs** and orchestrate them as A2A-compatible HTTP agents. Send the same question to 3 models and compare (fanout), chain write → review → synthesize across families (pipeline), or let each family spin up its own sub-sidecars for deeper reasoning (-team variants).

### 10 supported backends

| Backend | CLI | Strengths |
|---|---|---|
| **Kimi** | `kimi-code` | 262K context, Chinese coding |
| **GLM** | `glm-code` | Reasoning, Chinese understanding |
| **Doubao** | `doubao-code` | 5-tier auto-routing, general CN |
| **Qwen** | `qwen-code` | SQL, Alibaba ecosystem |
| **MiniMax** | `minimax-code` | Fast inference, low latency |
| **MiMo** | `mimo-code` | Experimental, 1M context |
| **StepFun** | `stepfun-code` | Math, logic, proofs |
| **Codex** | `codex` | GPT-5.4, algorithms, English |
| **Gemini** | `gemini` | 1M context, multi-file review |
| **Claude** | `claude` | Anthropic native, reasoning |

Every backend also supports a **`-team` variant** (e.g. `kimi-code-team`, `claude-team`) that internally creates 2-3 same-family sidecars via agent-teams, reasons independently, then synthesizes one final answer.

---

## Quick start

### Path A — Marketplace install (5 min)

```
/plugin marketplace add LeoLin990405/mmteam-cc
/plugin install mmteam@mmteam-cc
/reload-plugins
/mmteam:setup
```

### Path B — Clone + install (for full control)

```bash
git clone https://github.com/LeoLin990405/mmteam-cc.git
cd mmteam-cc
bash install.sh          # copies bin to PATH + registers MCP
# Restart Claude Code to activate mcp__mmteam__a2a_* tools
```

---

## Usage

### 1. Create a team

```bash
/mmteam:create demo kimi:kimi-code gpt:codex gem:gemini
```

### 2. Start daemons

```bash
/mmteam:spawn demo               # headless (fastest)
/mmteam:spawn demo --dock         # cmux multi-pane grid
/mmteam:spawn demo --dock --monitor  # + top event strip
```

### 3. Orchestrate

```bash
# Single smart-routed ask
/mmteam:ask demo "用 Python 实现 LRU Cache"

# Parallel fanout — 3 models answer, compare consensus
/mmteam:fanout demo "Is 91 prime? Answer ONLY prime or composite" --agents kimi,gpt,gem

# Sequential pipeline — write → review → synthesize
/mmteam:pipeline demo "Build a REST API for todo app" --writer kimi --reviewer gem --synth gpt

# Direct send to one teammate
/mmteam:send demo kimi "分析这段 500K token 日志"

# Watch live output in cmux dashboard
/mmteam:watch demo
```

### 4. Clean up

```bash
/mmteam:stop demo      # stop daemons, keep data
/mmteam:destroy demo   # remove everything
```

---

## All slash commands

| Command | Purpose |
|---|---|
| `/mmteam:create` | Create team with named teammates |
| `/mmteam:spawn` | Start A2A HTTP daemons |
| `/mmteam:stop` | Stop daemons + close cmux workspace |
| `/mmteam:destroy` | Full cleanup (daemons + data) |
| `/mmteam:status` | Show members, liveness, stats |
| `/mmteam:ask` | Smart-routed single dispatch |
| `/mmteam:send` | Direct send to named teammate |
| `/mmteam:fanout` | Parallel broadcast + consensus analysis |
| `/mmteam:pipeline` | Write → review → synthesize chain |
| `/mmteam:watch` | Open cmux live dashboard |
| `/mmteam:unwatch` | Close dashboard |
| `/mmteam:remote` | Register cross-host teammate |
| `/mmteam:setup` | First-run installer + diagnostics |

---

## MCP bridge

After install, Claude Code can call mmteam natively via 20+ MCP tools:

```
mcp__mmteam__a2a_spawn     mcp__mmteam__a2a_send
mcp__mmteam__a2a_fanout    mcp__mmteam__a2a_pipeline
mcp__mmteam__a2a_ask       mcp__mmteam__a2a_stop
mcp__mmteam__a2a_ls        mcp__mmteam__a2a_watch
...
```

This means Claude can autonomously decide to dispatch tasks to teammates during a conversation — no slash command needed.

---

## Architecture

```
Claude Code (main session)
  │
  ├── /mmteam:* slash commands
  │      └── mmteam-bridge.mjs → bin/mmteam CLI
  │
  └── mcp__mmteam__a2a_* (native MCP tools)
         └── bin/mmteam-mcp.py (stdio JSON-RPC)
                │
                │  JSON-RPC 2.0 over HTTP + Bearer token
                │
       ┌────────┼────────┬────────────┐
       ▼        ▼        ▼            ▼
    a2a-srv  a2a-srv  a2a-srv     a2a-srv
    :port₁   :port₂   :port₃      :portₙ
       │        │        │            │
       ▼        ▼        ▼            ▼
    kimi-code  codex   gemini    glm-code-team
    (headless) (headless) (headless) (agent-teams)
                                      └→ 2-3 GLM sidecars
                                         → synthesized reply
```

**Protocol**: Google A2A v0.3 minimal subset — Agent Card discovery, `message/send`, `tasks/get`, `tasks/cancel`, Bearer auth.

---

## -team variants (agent-teams sub-sidecars)

Append `-team` to any CLI name to enable internal multi-sidecar reasoning:

```bash
/mmteam:create deep kt:kimi-code-team ct:claude-team
/mmteam:spawn deep
/mmteam:fanout deep "Design a distributed cache" --agents kt,ct
```

Each `-team` teammate internally:
1. Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
2. Wraps the prompt with `TeamCreate` instructions
3. Spawns 2-3 same-family sidecars that reason independently
4. Synthesizes a single final answer

Agent Card shows `family: anthropic-agent-teams` and `skills[0]: parallel-sidecars`.

---

## Cross-host teammates

Register a teammate running on another machine:

```bash
# On remote host (Mac Studio):
mmteam a2a spawn myteam
jq -r '.kimi.bearer_token' ~/.claude/teams/myteam/a2a-registry.json

# On local host:
/mmteam:remote myteam kimi-studio http://studio.local:55723/ --token <TOKEN>
/mmteam:send myteam kimi-studio "Analyze this large codebase"
```

See [docs/REMOTE-TEAMMATE.md](docs/REMOTE-TEAMMATE.md).

---

## Requirements

| Dependency | Required | Notes |
|---|---|---|
| Claude Code | Yes | Plugin host |
| Python ≥ 3.9 | Yes | A2A server + MCP server |
| Node.js ≥ 18 | Yes | Bridge scripts |
| CC launchers | At least 1 | `kimi-code`, `glm-code`, etc. — install via [cn-cc](https://github.com/LeoLin990405/cn-cc) |
| cmux | Optional | Enables `--dock`, `--monitor`, `/mmteam:watch` |
| jq | Optional | Better JSON output formatting |

Run `bash doctor.sh` to check your setup.

---

## Relationship to cn-cc

[cn-cc](https://github.com/LeoLin990405/cn-cc) provides **single-point `/cn:*` slash commands** for routing individual tasks to Chinese model backends.

**mmteam-cc** provides **multi-model orchestration** — teams, fanout, pipelines, consensus, cross-host.

They are **complementary**:
- Simple one-off Chinese model task → `/cn:ask`
- Multi-model consensus or staged workflow → `/mmteam:fanout` or `/mmteam:pipeline`
- Both can be installed side by side.

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `mmteam: command not found` | Run `bash install.sh` or add `~/.local/bin` to PATH |
| MCP tools not showing in CC | Restart Claude Code after install |
| Dock/watch not working | Install cmux or use `--no-dock` |
| Teammate daemon won't start | Check `~/.claude/teams/<team>/<agent>.a2a.log` |
| `register-mcp: cannot parse` | Check `~/.claude.json` is valid JSON |

Full diagnostics: `bash doctor.sh`

---

## Files

```
mmteam-cc/
├── bin/                    # Vendored mmteam v2.18 scripts
│   ├── mmteam              # Main CLI (1637 lines)
│   ├── mmteam-a2a-server.py # Per-teammate HTTP daemon
│   ├── mmteam-a2a-monitor.py # Event stream viewer
│   └── mmteam-mcp.py       # MCP stdio server (20 tools)
├── plugins/mmteam/         # Claude Code plugin
│   ├── commands/           # 13 slash commands
│   ├── agents/             # mmteam-orchestrator
│   ├── skills/mmteam/      # SKILL.md + ROUTING.md
│   └── scripts/            # Bridge + MCP registrar
├── install.sh              # One-shot bootstrap
├── uninstall.sh            # Clean removal
├── doctor.sh               # Health diagnostics
├── docs/                   # Deep-dive documentation
├── examples/               # Usage recipes
└── tests/smoke/            # CI smoke tests
```

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).

This project implements wire-compatible subsets of the [A2A Protocol](https://a2a-protocol.org) and [MCP](https://spec.modelcontextprotocol.io) but is not affiliated with their respective organizations. See [NOTICE](NOTICE).
