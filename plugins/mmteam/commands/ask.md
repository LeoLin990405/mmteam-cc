---
description: Intelligently route a prompt to the best teammate by skill match
argument-hint: '<team-name> "<prompt>"'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Auto-select the best teammate for the given prompt by matching keywords (SQL / 数学 / 长文 / 快速 / ...) against each teammate's Agent Card skills — then dispatch via `send`.

Keyword → preferred family:
- `sql` / `doris` / `polardb` / `查询` → qwen-code
- `math` / `数学` / `prove` / `证明` / `定理` → stepfun-code
- `long` / `100K` / 长文 → kimi-code
- `fast` / `quick` / `速度` → minimax-code
- `experimental` / 实验 → mimo-code
- `算法` / `english` → codex
- `多文件` / `review` / `1M` → gemini

Quota-aware: teammates whose 5h window is ≥80% used get a 0.5× score penalty; ≥95% used are skipped.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" ask $ARGUMENTS`

For a dry-run preview of the routing decision (zero quota cost), use `mmteam a2a routes <team> "<prompt>"`.
