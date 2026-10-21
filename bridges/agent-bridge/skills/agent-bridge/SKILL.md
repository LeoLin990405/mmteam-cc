---
name: agent-bridge
description: Use when Leo wants to dispatch a coding/review/research task to a specific external AI surface (Codex App/CLI, Antigravity, Trae SOLO, Qoder CLI) and collect the result synchronously. Provides 5 unified surface bridges, project/thread/mode routing, and a reverse-callback inbox so child agents can ping back. Invoke before reaching for `codex exec` / `qodercli` / etc. directly.
---

# agent-bridge — 5-surface orchestrator

One CLI, five surfaces, four layers. Use this skill whenever a task fits
"send work to a specific external AI app/CLI and wait for the answer."

## The 5 surfaces

| Surface | Bridge script | Strengths | State model |
|---|---|---|---|
| `codex-cli` | `codex-cli-bridge.sh` | Backend code, English prompts, refactors | Stateless per-invocation |
| `codex-app` | `codex-bridge.sh` (App) | Codex Desktop quota, multi-thread project context | Multi-thread (project + ThreadId) |
| `antigravity` | `antigravity-bridge.sh` | Frontend UI, Gemini-family reasoning | Single active conversation |
| `qoder-cli` | `qoder-cli-bridge.sh` | Alibaba ecosystem, SQL, Coding Plan quota | Stateless per-invocation |
| `trae-solo` | `trae-solo-bridge.sh` | TRAE SOLO IDE-integrated Builder Agent | Multi-project (task-list-group) + chat sessions |

Pick by what Leo asked for. If unsure, ask — never auto-pick a surface
for "ambiguous task" by inferring intent.

## 4 layers of capability

### Layer 1 — Inventory (read state before you act)

```
agent-bridge <surface> list      # JSON: {surface, active_session, sessions[]}
agent-bridge <surface> modes     # JSON: {surface, axis, active_mode, available_modes[]}
agent-bridge --status            # all-surface health matrix
agent-bridge --list              # which bridges are installed
```

When to read inventory: before sending a task that depends on which
project/thread the surface is currently on. Example: "ask Codex App about
the meme generator project" → first `agent-bridge codex-app list` to
confirm the meme-generator thread exists and find its `id`.

### Layer 2 — CLI routing args (explicit)

```
agent-bridge <surface> ask|review <prompt-or-file> \
  --project <name>          # surface-specific (project name / dir / workspace)
  --thread  <id|current|auto-new>
  --mode    <id>            # surface-specific (model / sandbox / agent-config)
  --timeout <seconds>
```

### Layer 3 — Frontmatter routing (lives with the prompt)

Put routing directives in the prompt file itself:

```
---
@project: nd0044-fyyur
@thread: auto-new
@mode: gpt-5-codex
---

Actual prompt body here...
```

Also supports bare `@key=val` lines at the top (no fence). CLI flags
override frontmatter. Use frontmatter when the prompt is checked into a
repo and should carry its routing with it.

### Layer 4 — Reverse-callback inbox (child → parent)

When the child agent needs to ping Leo (or you, the orchestrator), it
embeds markers in its reply. The bridge auto-extracts them.

Three marker formats — pick whichever fits the message:

```
@callback-claude: Single-line message.
@callback-claude[topic-slug]: Single-line with topic.

<<CALLBACK[topic-slug]>>
Multi-line message.
Code blocks fine, anything goes.
<<END>>
```

Inbox commands:
```
agent-bridge inbox list [--unread-only]
agent-bridge inbox read <id-or-slug>     # prints + marks as read
agent-bridge inbox clear --older-than-hours 24
```

When orchestrating in a `/loop` or with `ScheduleWakeup`, poll
`agent-bridge inbox list --unread-only` between iterations.

## Decision flow

```
Task arrives
  │
  ├── Need surface inventory? → agent-bridge <surface> list / modes
  │
  ├── Pick surface (per Leo's preference / task type)
  │
  ├── Routing decision:
  │     CLI flags?   → pass --project/--thread/--mode
  │     Frontmatter? → write to prompt file head
  │     Both?        → CLI wins
  │
  ├── Send:
  │     agent-bridge <surface> ask "<prompt>"               # quick
  │     agent-bridge <surface> review <prompt-file>         # full closed loop (VERDICT/ISSUES_COUNT)
  │
  ├── Bridge returns:
  │     RESPONSE_FILE=...
  │     ---
  │     <full text>
  │     [callback] N message(s) extracted to ~/.claude/inbox/  ← if any
  │
  └── If callbacks: agent-bridge inbox list → read → act
```

## Cross-bridge consistency

Every bridge guarantees the same output shape:

```
VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN          # review only
ISSUES_COUNT=N                              # review only
RESPONSE_FILE=/tmp/<surface>-bridge/...md
---
<full markdown response>
```

So Claude can write one parser for review output across all 5 surfaces.

## Operational checks

Before sending real work:

```
agent-bridge --status        # see which surfaces are reachable right now
```

Common "down" reasons:
- **codex-app**: Codex Desktop App not running, or `~/.claude/bin/codex-launch-with-cdp.sh` not run
- **antigravity**: needs `antigravity-launch-with-cdp.sh` (CDP) + `antigravity-serve-up.sh` (HTTP)
- **trae-solo**: needs `trae-solo-launch-with-cdp.sh` + chat panel open
- **qoder-cli**: first-time OAuth login required (run `qodercli status` interactively once)
- **codex-cli**: just needs `codex` in PATH (no setup)

See `references/` for surface-specific details.

## References (load on demand)

- `references/surface-codex-app.md`  — Codex Desktop App specifics, model switch, thread ops
- `references/surface-antigravity.md` — Antigravity HTTP serve + CDP ws probe
- `references/surface-trae-solo.md`   — Lexical editor pitfalls, Completed marker
- `references/surface-codex-cli.md`   — sandbox modes, when to use --continue
- `references/surface-qoder-cli.md`   — Coding Plan vs Token Plan, --disallowed-tools
- `references/layer-3-frontmatter.md` — full @key=val syntax + parser internals
- `references/layer-4-inbox.md`       — callback marker grammar, polling patterns
- `references/troubleshooting.md`     — 403 ws origin, idle timeout, Lexical paste failures

## Do NOT

- Do NOT pick a surface for Leo — ask when ambiguous.
- Do NOT run `codex exec` / `qodercli` directly — use the bridge so output
  shape is uniform and callbacks get extracted.
- Do NOT specify `--mode` / model identifiers Leo hasn't authorized for
  this task (see `feedback_5_agents_no_model.md` rule).
- Do NOT poll the inbox more often than every 60s in `/loop` — it's
  cheap but pointless faster than agents reply.
