---
description: "Autonomous supervisor loop: auto-decompose task → dispatch to agents → cross-review → retry failures → synthesize final output"
argument-hint: '<team> "<task-description>" [--max-retries N] [--cost-ceiling $] [--no-review] [--no-synth]'
context: fork
allowed-tools:
  - Bash
---

Runs the full brain loop as a single CLI command: decomposes the task into subtasks,
dispatches each to the best agent, cross-reviews with a different agent, retries on
low scores, and synthesizes the final output.

## Usage

```
/mmteam:supervise <team> "<task>" [options]
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--max-retries N` | 2 | Max retries per subtask when review score < 7/10 |
| `--cost-ceiling $` | 0.50 | Pause if cumulative cost exceeds this USD |
| `--no-review` | off | Skip cross-review (faster, lower quality assurance) |
| `--no-synth` | off | Return raw subtask outputs without synthesis |
| `--subtasks-file PATH` | auto | Read subtask list from file instead of auto-decompose |
| `--json` | off | Structured JSON output |

## Examples

```
/mmteam:supervise dev "实现一个 Go HTTP 中间件框架，支持 chain + context + error handling"
/mmteam:supervise research "对比 5 种向量数据库的性能特征" --no-review
/mmteam:supervise dev "重构认证模块" --subtasks-file tasks.txt --cost-ceiling 1.00
```

## Implementation

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" supervise "$@"
```
