# 任务路由决策指南 — agent-teams vs mmteam A2A vs 直调

当 Claude 要派工时，按下面决策树选框架。三个选项各自有最佳场景，不要通用化为"always mmteam"或"always agent-teams"。

## 决策树

```
任务需要多个 agent 协作吗？
├── 否 → 直接调（Bash 或单个 mcp tool）
└── 是 → 需要跨厂商模型多样性吗？
         ├── 否（只要 Claude 深度推理）
         │    └── 需要 Anthropic 专属工具/skill/内部 MCP？
         │         ├── 是 → 官方 agent-teams (TeamCreate)
         │         └── 否 → 看成本：Claude 套餐够/deadline 紧 → agent-teams
         │                                ； 预算紧 → mmteam a2a kimi-code
         └── 是（要混合 Kimi + Gemini + Codex 等）
              └── mmteam a2a（唯一方案）
                   ├── 要看实时思考 → --dock --monitor
                   └── 只要 artifact → headless（默认，快）
```

## 框架对比表（决策维度）

| 维度 | 官方 agent-teams | mmteam A2A | 直调 |
|---|---|---|---|
| Teammate 类型 | Claude sidecar（同家族） | 任意 CLI（跨厂商） | 单一 CLI |
| 开队成本 | ~5s（内进程） | ~1s headless / ~10s dock | 0s |
| Token 成本 | 每 sidecar 一份主会话开销 | 每 teammate 独立 quota（可混套餐） | 最低 |
| 跨机 | ❌ | ✅ | ❌ |
| Claude 专属特性 | ✅ skills/MCP 嵌套 | ❌ | ✅ 主 CC 能用 |
| 可观察性 | TUI 切换（Shift+↑↓） | cmux 多 pane + 事件条 | 主 CC 日志 |
| 调用接口 | TeamCreate/SendMessage 工具 | mcp__mmteam__a2a_* | 任何 MCP/Bash |
| 并发度 | 单进程 multiplex | 每 teammate 独立 daemon | 单线程 |
| 会话状态 | sidecar 维持 | dock 保留 / headless 裸 | 主 CC 继承 |

## 典型任务 → 框架映射

| 任务类型 | 首选 | 备选 |
|---|---|---|
| 3 个假设并行调试一个 bug（纯 Claude 思考） | agent-teams | - |
| 同题跨模型 A/B 比较（Kimi vs Gemini vs Codex） | **mmteam a2a**（同题广播） | - |
| 长文（500K+ tokens）深度分析 | mmteam a2a gemini（1M 上下文） | - |
| 复杂项目拆成子模块并行开发（Claude 主审） | agent-teams（sidecar 写代码，主 CC 整合） | - |
| 中文业务逻辑 + SQL（省 Claude 套餐） | mmteam a2a kimi/qwen | agent-teams（贵） |
| 跨机：Studio 思考 + mini 执行 | mmteam a2a（register remote） | - |
| 成本敏感的多轮迭代 | mmteam a2a dock（会话复用省 token） | - |
| 一步到位简单查询 | 直调（不开队） | - |
| 算法题需多模型交叉验证 + 代码审查 | **混合**：agent-teams 3 Claude 并行假设 + mmteam a2a codex 做最终算法 | - |

## 混合模式：两者同时用

主 CC 同时持有两种能力，按步骤分工：

```
步骤 1: 用 agent-teams 3 个 Claude sidecar 并行提假设
    → TeamCreate({name:"hyps", members:[h1,h2,h3]})
    → SendMessage 分派各自任务

步骤 2: 用 mmteam a2a 跨厂商复核某个关键假设
    → mcp__mmteam__a2a_send({team:"verify", agent:"gemini", text:"验证假设 2..."})
    → mcp__mmteam__a2a_send({team:"verify", agent:"kimi", text:"同上"})

步骤 3: 主 CC 整合所有输入，给结论
```

**命名约定**：避免 `~/.claude/teams/<name>/` 撞车
- 官方 agent-teams：`cc-<purpose>`（如 `cc-hypotheses`, `cc-review`）
- mmteam A2A：`a2a-<purpose>`（如 `a2a-verify`, `a2a-cross-model`）

## 7 家 CC 分身选型速查（v2.9）

每家分身根据 vault memory 里记录的真实模型特性，挂不同 skill 标签。`mmteam a2a ask` 按 prompt 关键词路由自动选。手动调用时对照：

| 场景 | 首选 | 独家 skill | 原因 |
|---|---|---|---|
| 长文档/大文件分析（>100K token） | **kimi-code** | `long-context` | K2.6-code 262K 家族最长 |
| SQL / 数据库 / 阿里云 | **qwen-code** | `sql-engineering` | qwen3-coder + 百炼 DashScope |
| 数学证明 / 逻辑推导 | **stepfun-code** | `math-logic` | step-3.5-flash 默认开 thinking |
| 快速响应（首字延迟敏感） | **minimax-code** | `fast-inference` | M2.7-highspeed 档 |
| 中文推理 / 智谱套餐 | **glm-code** | `reasoning-effort` | GLM-4.7/5.1 |
| 复杂任务自动选型 | **doubao-code** | `provider-routing` | ark-code-latest 5 档真分路由 |
| 实验性新模型 | **mimo-code** | `experimental-model` | mimo-v2-pro/omni 探索 |
| 算法题 / 英文编码 | `codex` | `algorithm-design` | GPT-5.4 底座 |
| 1M 超长 / 多文件审查 | `gemini` | `long-context · multi-file-review` | Gemini 2.5 Pro 1M ctx |
| Anthropic 原生 | `claude` | `code-execution · reasoning-effort` | Claude 主 session 分身 |
| **Claude 子团队编排（agent-teams）** | **`claude-team`** | `parallel-sidecars` | v2.11 接入：Claude 内部起 2-3 个 sidecar 并行，再综合；适合需要"多视角独立推理再融合"的任务 |
| **任意家族子团队并行再综合（v2.18）** | **`{slug}-code-team`** | `parallel-sidecars` + 家族 skills | 7 家 CC 分身全部支持 `-team` 后缀：`kimi-code-team` / `glm-code-team` / `doubao-code-team` / `qwen-code-team` / `minimax-code-team` / `mimo-code-team` / `stepfun-code-team`。teammate 内部 `TeamCreate` 同家族 sidecar 并行后再综合，family=`anthropic-agent-teams` |

**自动路由关键词**（prompt 里命中即加分）：
- SQL/数据库 → qwen：`sql` / `doris` / `polardb` / `mysql` / `查询` / `join`
- 数学/证明 → stepfun：`math` / `数学` / `prove` / `证明` / `定理` / `质数`
- 快速 → minimax：`fast` / `quick` / `速度` / `urgent`
- 长文 → kimi：`long` / `big file` / `100K` / `分析`
- 实验 → mimo：`实验` / `experimental` / `trial`

## 分身自己也能开 agent-teams（2026-04 起）

`kimi-code` / `glm-code` / `doubao-code` / `qwen-code` / `minimax-code` / `mimo-code` / `stepfun-code` 7 家启动器都已 `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`。

意味着每家分身**同家族内部也可以 TeamCreate**：
- 在 `kimi-code` 里 `TeamCreate` → 3 个 Kimi sidecar 同套餐协作
- Kimi Allegretto 套餐 300-1200 reqs/5h，并发 30，开 team 成本低

这打开了"**外部 CLI 进到 A2A，再在 A2A 下开 sub-team**"的三层嵌套：

```
主 CC (agent-teams) ──→ sc1(Claude)
                   └──→ mmteam A2A kimi-code(agent-teams) ──→ k1, k2, k3 (Kimi sub-team)
                                                         └──→ (agg) 返 A2A artifact
```

### v2.18：`-team` 后缀直接作为 A2A teammate 类型

v2.11 只接了 `claude-team`；v2.18 起 **全 7 家** 都有 `-team` 变体，可直接在 `mmteam create` 里用：

```bash
# "每家族各自 sub-team → 再跨家族 fanout" 的高质量队伍
mmteam create poly \
  kt:kimi-code-team \
  gt:glm-code-team \
  st:stepfun-code-team \
  ct:claude-team
mmteam a2a spawn poly
mmteam a2a fanout poly "CAP 定理用三个维度分析" --agents kt,gt,st,ct
```

每 teammate 内部自动 `TeamCreate` 2-3 个同家族 sidecar → 分派 → 合成，只把最终答案返给外层。Agent Card 的 `family=anthropic-agent-teams`，`skills` 首位固定 `parallel-sidecars`，其余保留家族特色。代价：每家族请求数 ×3，适合"多视角独立再融合"的高质量任务。

## 判断何时嵌套 vs 平铺

**平铺**（第一选择）：
- 任务能被独立分解（并行 assumptions、并行 audits）
- 每个 teammate 做完整子任务
- 成本可控

**嵌套**（谨慎选）：
- 子任务本身复杂到需要内部 sub-team 分解
- 顶层 token 太贵（Claude 昂贵），下沉到便宜 family
- 有真实的"多层组织结构"对应现实工作流

避免 ≥3 层嵌套 — 延迟累积、成本指数、调试困难。

## 启用 checklist（2026-04）

- [x] 主 CC：`~/.zshrc` 加 `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- [x] 7 个 CC 分身启动器都内置 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- [x] mmteam MCP 已注册在 `~/.claude.json`
- [x] mmteam A2A HTTP + cmux dock + monitor 可用

重启 CC 后即可同时使用。
