---
description: Broadcast the same prompt to N teammates and analyze consensus
argument-hint: '<team-name> "<prompt>" [--agents a,b,c] [--judge X] [--json]'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Parallel broadcast. Returns each teammate's reply plus:
- **Pairwise Jaccard similarity** (CJK bigram + English token) matrix
- **Outlier flag** for replies that diverge significantly from the group
- **Optional LLM-as-judge synthesis** via `--judge <agent-id>` — the named teammate consolidates all replies into one answer

`--agents a,b,c` narrows the fanout to a subset. `--json` emits machine-readable output. Teammates with ≥95% quota usage are auto-skipped.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" fanout $ARGUMENTS`

Typical use: cross-model consensus on factual questions, A/B-testing code implementations, validating an answer across family boundaries.
