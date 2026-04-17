# Teammate Types

mmteam supports **10 base backends** and **10 `-team` variants** (total 20 teammate types).

## Base backends

| CLI | Family | Context | Unique skill | Best for |
|---|---|---|---|---|
| `kimi-code` | anthropic-compat | 262K | `long-context` | Large file analysis, Chinese coding |
| `glm-code` | anthropic-compat | 128K | `reasoning-effort` | Chinese reasoning, understanding |
| `doubao-code` | anthropic-compat | 256K | `provider-routing` | General CN coding, auto 5-tier routing |
| `qwen-code` | anthropic-compat | 131K | `sql-engineering` | SQL, Alibaba/Doris/PolarDB |
| `minimax-code` | anthropic-compat | 200K | `fast-inference` | Low-latency responses |
| `mimo-code` | anthropic-compat | 128K | `experimental-model` | Experimental / vision |
| `stepfun-code` | anthropic-compat | 65K | `math-logic` | Math proofs, logic, thinking |
| `codex` | openai | 400K | `algorithm-design` | English algorithms, GPT-5.4 |
| `gemini` | google | 1M | `multi-file-review` | Cross-file review, 1M context |
| `claude` | anthropic | 1M | `reasoning-effort` | Anthropic native, deep reasoning |

## -team variants (agent-teams sub-sidecars)

Append `-team` to any CLI name. The teammate internally spawns 2-3 same-family sidecars for independent parallel reasoning, then synthesizes one answer.

| Variant | Base | Family tag | Example use case |
|---|---|---|---|
| `claude-team` | claude | `anthropic-agent-teams` | Multi-perspective reasoning on complex problems |
| `kimi-code-team` | kimi-code | `anthropic-agent-teams` | Long-doc analysis with 3 parallel reads |
| `glm-code-team` | glm-code | `anthropic-agent-teams` | Chinese reasoning with cross-validation |
| `doubao-code-team` | doubao-code | `anthropic-agent-teams` | Provider-routing + sub-team exploration |
| `qwen-code-team` | qwen-code | `anthropic-agent-teams` | SQL cross-checking with 3 sidecars |
| `minimax-code-team` | minimax-code | `anthropic-agent-teams` | Fast multi-path reasoning |
| `mimo-code-team` | mimo-code | `anthropic-agent-teams` | Experimental multi-sidecar |
| `stepfun-code-team` | stepfun-code | `anthropic-agent-teams` | Math proof from 3 angles |

### When to use -team

- Task is complex enough to benefit from independent reasoning before fusion
- You want to stay within one family's quota (no cross-family cost)
- Verification tasks: 3 sidecars solve independently, then agree or disagree

### When NOT to use -team

- Simple tasks (overhead of sub-team is wasted)
- Cross-family comparison (use base types with `/mmteam:fanout` instead)
- Very fast turnaround needed (sub-team adds ~2-3x latency)

## Agent Card skills mapping

Each teammate's Agent Card (at `GET /.well-known/agent-card.json`) lists its skills array. The `mmteam a2a ask` router and `mmteam-orchestrator` agent match prompt keywords against these skills.

**Keyword routing examples**:
- "SQL" / "Doris" / "join" → matches `sql-engineering` → qwen-code
- "math" / "proof" / "prime" → matches `math-logic` → stepfun-code
- "long file" / "100K" → matches `long-context` → kimi-code
- "fast" / "urgent" → matches `fast-inference` → minimax-code
- "experimental" → matches `experimental-model` → mimo-code

## Quota awareness

Teammates backed by subscription plans (Kimi Allegretto, GLM Plan, etc.) have rolling 5h request caps. The router penalizes teammates at ≥80% usage (0.5× score) and skips those at ≥95%.

View current quota: `mmteam a2a quota <team>`
Preview routing without cost: `mmteam a2a routes <team> "<prompt>"`
