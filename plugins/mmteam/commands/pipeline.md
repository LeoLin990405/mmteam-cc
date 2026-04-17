---
description: Run a write→review→synthesize 3-stage pipeline across teammates
argument-hint: '<team-name> "<prompt>" --writer <agent> --reviewer <agent> --synth <agent>'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

3-stage sequential pipeline:

1. **writer** — produces initial artifact from `<prompt>`
2. **reviewer** — critiques the writer's output
3. **synth** — integrates prompt + draft + review into a final polished answer

Each stage receives upstream outputs as context. Emits incremental results — watch them land in real time with `/mmteam:watch <team>` in another session.

Typical casting:
- Writer: kimi-code (long context, Chinese)
- Reviewer: gemini (1M ctx, cross-file analysis)
- Synth: codex (English precision) or claude (native reasoning)

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" pipeline $ARGUMENTS`
