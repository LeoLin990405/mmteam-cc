# Example: Write → Review → Synthesize Pipeline

Chain three teammates in sequence, each building on the previous output.

## Setup

```bash
mmteam create pipe writer:kimi-code reviewer:gemini synth:codex
mmteam a2a spawn pipe
```

## Run

```bash
mmteam a2a pipeline pipe "Build a Python REST API for a todo app with CRUD endpoints" \
  --writer writer --reviewer reviewer --synth synth
```

### What happens

1. **writer** (kimi-code) — writes the initial implementation
2. **reviewer** (gemini, 1M context) — receives the code + original prompt, critiques it
3. **synth** (codex, GPT-5.4) — receives prompt + code + review, produces the polished final version

Each stage's output is saved to `~/.claude/teams/pipe/results/`.

## Typical casting

| Stage | Recommended | Why |
|---|---|---|
| Writer | kimi-code / doubao-code | Domain specialist, generates first draft |
| Reviewer | gemini | 1M context sees everything, good at critique |
| Synth | codex / claude | Precise, integrates feedback cleanly |

## Cleanup

```bash
mmteam a2a stop pipe && mmteam destroy pipe
```
