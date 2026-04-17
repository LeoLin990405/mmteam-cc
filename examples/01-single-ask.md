# Example: Single Smart-Routed Ask

The simplest use case — let mmteam pick the best teammate for your question.

## Setup

```bash
mmteam create demo kimi:kimi-code qwen:qwen-code gpt:codex
mmteam a2a spawn demo
```

## Run

```bash
# mmteam auto-selects based on prompt keywords
mmteam a2a ask demo "写一个 Python 快速排序函数"
# → likely routes to kimi-code (Chinese coding)

mmteam a2a ask demo "Write a SQL query to join users and orders"
# → likely routes to qwen-code (SQL keyword match)

mmteam a2a ask demo "Implement Dijkstra's algorithm in Rust"
# → likely routes to codex (algorithm + English)
```

## Preview routing without cost

```bash
mmteam a2a routes demo "写一个 Python 快速排序函数"
# Shows each teammate's score + selected winner (no API call)
```

## Cleanup

```bash
mmteam a2a stop demo && mmteam destroy demo
```
