# Example: -team Variant (Internal Sidecars)

Use `-team` variants for multi-perspective reasoning within a single model family.

## Setup

```bash
mmteam create deep kt:kimi-code-team ct:claude-team
mmteam a2a spawn deep
```

## Run

```bash
# Each teammate internally spawns 2-3 sidecars, reasons in parallel, synthesizes
mmteam a2a send deep kt "设计一个分布式锁服务，要考虑网络分区和时钟漂移"
```

### What happens inside `kimi-code-team`:
1. Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
2. Main Kimi session calls `TeamCreate` with 2-3 sidecars
3. Each sidecar independently analyzes the distributed lock problem
4. Main session collects all perspectives and synthesizes one answer
5. Only the final synthesis is returned to mmteam

## Cross-family comparison with -team

```bash
# Two families, each with internal sub-teams, then fanout to compare
mmteam a2a fanout deep "Prove that √2 is irrational" --agents kt,ct
```

This gives you "multi-angle reasoning within each family" + "cross-family consensus" — the deepest analysis mode.

## Trade-offs

| | Base variant | -team variant |
|---|---|---|
| Speed | 1× | ~3× slower (sub-team overhead) |
| Quota usage | 1 request | ~3 requests per family |
| Answer depth | Single perspective | Multi-perspective synthesis |

## Cleanup

```bash
mmteam a2a stop deep && mmteam destroy deep
```
