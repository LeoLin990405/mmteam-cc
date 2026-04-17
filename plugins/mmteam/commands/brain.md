---
description: "Brain mode: CC decomposes task → dispatches to agents → cross-reviews → retries → synthesizes"
argument-hint: '<team> "<task-description>"'
context: fork
allowed-tools:
  - Bash
---

CC acts as project manager ("brain") for a complex task. Decomposes into subtasks,
dispatches each to the best teammate, sends results to a different agent for cross-review,
retries failures with reviewer feedback, and synthesizes the final output.

## Usage

```
/mmteam:brain <team> "<task-description>"
```

## Examples

```
/mmteam:brain dev "实现一个支持并发的 Go channel pool，要求有单元测试和性能基准"
/mmteam:brain research "对比 RAG vs fine-tuning vs prompt engineering 三种方案，给出选型建议"
/mmteam:brain dev "重构 auth 模块：拆分 JWT 生成/验证/刷新，写迁移文档"
```

## What happens

1. Checks team exists and who's alive (`mmteam a2a who`)
2. Decomposes task into ≤5 subtasks
3. For each subtask: picks best agent, dispatches via `mmteam a2a send`
4. Cross-reviews: sends each result to a different agent for quality check
5. If review fails (score < 7/10): retries with feedback (max 2 retries)
6. Synthesizes all accepted results into final output
7. Reports cost and token usage

## Implementation

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" a2a who "$1"
```

Then the orchestrator agent (brain mode) takes over the multi-step workflow using
sequential `mmteam a2a send/fanout/pipeline` calls based on task decomposition.
The orchestrator manages the full lifecycle — no single CLI command covers this;
it requires iterative agent reasoning between dispatch steps.
