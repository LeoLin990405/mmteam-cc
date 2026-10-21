# agent-bridge

> Same-process sync bridges that turn 5 AI coding surfaces (Codex CLI, Codex Desktop App, Antigravity, Qoder CLI, Trae SOLO) into a unified callable API. Built for Claude Code to drive a multi-agent pipeline where each `agent-bridge <surface> review <prompt>` call blocks until the agent finishes — no polling, no manual prompt/verdict copy-paste.

## What it does

Each surface gets a thin bash wrapper exposing the same 3 verbs:

```bash
agent-bridge <surface> status                            # ping the surface's bridge
agent-bridge <surface> ask    <text>      [--timeout S]  # sync push prompt + wait for response
agent-bridge <surface> review <prompt-file> [--timeout S] # full review loop + parse VERDICT
```

Where `<surface>` is one of:

| surface | underlying call | what the agent runs |
|---|---|---|
| `codex-cli` | `codex exec` direct stdin/stdout | OpenAI Codex CLI (`codex-cli` v0.132+) |
| `codex-app` | `opencli codex ask` (CDP-driven Desktop App) | Codex Desktop macOS app |
| `antigravity` | `opencli antigravity serve` → HTTP `/v1/messages` | Google Antigravity IDE (Gemini backend) |
| `qoder-cli` | `qodercli -p ... -f json` | Alibaba Qoder AI terminal CLI |
| `trae-solo` | `opencli browser` over CDP :9235 | ByteDance Trae SOLO IDE |

`review` output is a strict, machine-parsed format:

```
VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
ISSUES_COUNT=N
RESPONSE_FILE=/tmp/<surface>-bridge/...md
---
<full markdown response>
```

So the calling Claude can branch on `VERDICT` and patch `NEEDS_FIX` issues directly (file:line specified by the reviewer).

## Why

When you orchestrate multiple AI coding agents from Claude Code, you end up either:

1. **Asking the human to bounce prompts between apps** — copy prompt to Codex, wait, paste verdict back. Slow.
2. **Polling DOM / hashing chat output** — fragile, latency-prone, violates "agent done → sync return" intent.

`agent-bridge` collapses both into the same shape: **agent completion = HTTP response / process exit / CDP return**. The bridge blocks; when it returns, the agent has finished. Claude reads the result and decides the next step.

This is the runtime layer of a 5-stage pipeline:

```
Claude plans → bridge dispatches → agent works → bridge syncs result → Claude patches if needed → loop
                ▶                                  ←                       ↻             ✓
```

## Quick start

### Install

```bash
git clone https://github.com/<your-fork>/agent-bridge.git ~/.claude/agent-bridge
cd ~/.claude/agent-bridge
bash install.sh           # links bin/ scripts to ~/.claude/bin/
```

### Prerequisites per surface

| surface | required |
|---|---|
| `codex-cli` | `npm i -g @openai/codex-cli` (provides `codex` in PATH) |
| `codex-app` | Codex Desktop App installed and running (Open-AI account) |
| `antigravity` | Antigravity.app installed → run `bin/antigravity-launch-with-cdp.sh --bg` once + `bin/antigravity-serve-up.sh` once per boot |
| `qoder-cli` | `qodercli` installed (Alibaba) + OAuth login (`qodercli status` interactively once) |
| `trae-solo` | TRAE SOLO.app installed → run `bin/trae-solo-launch-with-cdp.sh --bg` once per boot |

Also requires [`opencli`](https://github.com/jackwener/opencli) for `codex-app`, `antigravity`, `trae-solo`:

```bash
npm i -g @jackwener/opencli
```

### Check health

```bash
agent-bridge --status

# surface       | installed | bridge-status
# --------------+-----------+-------------------------
# codex-cli     | yes       | codex CLI: ~/.npm-global/bin/codex
# codex-app     | yes       | Connected
# antigravity   | yes       | ✓ serve listening on :8082
# qoder-cli     | yes       | qodercli: ~/.npm-global/bin/qodercli
# trae-solo     | yes       | ✓ CDP up on :9235
```

### Use it

```bash
# Dispatch a review to any ready surface
agent-bridge codex-cli  review /tmp/task-A-review.md
agent-bridge codex-app  review /tmp/task-A-review.md
agent-bridge qoder-cli  review /tmp/task-A-review.md
agent-bridge antigravity review /tmp/task-A-review.md --timeout 1200

# One-shot ask
agent-bridge codex-app ask "Reply only: pong"
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for the 5-surface design, [docs/workflow.md](docs/workflow.md) for the v5 pipeline integration, [docs/integration.md](docs/integration.md) for the overall roadmap and rationale.

## Status

| component | state |
|---|---|
| `agent-bridge` dispatcher | ✅ |
| `codex-cli-bridge.sh` | ✅ status verified |
| `codex-bridge.sh` (App) | ✅ status verified |
| `antigravity-bridge.sh` + launcher + serve-up | ✅ scripts ready, run launcher first |
| `qoder-cli-bridge.sh` | ✅ ready, first run needs OAuth login |
| `trae-solo-bridge.sh` | 🚧 in progress — CDP launcher ready, chat-DOM selector wrapping pending |

## Related

- **[opencli](https://github.com/jackwener/opencli)** — the underlying CDP/HTTP-bridge runtime; this project is a higher-level Claude-orchestrated layer on top of it
- **`/five-agents` Claude skill** — the workflow/SKILL.md side; see [docs/workflow.md](docs/workflow.md)

## License

Apache-2.0. Same as opencli upstream.
