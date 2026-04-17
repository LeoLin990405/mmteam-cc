---
name: mmteam
description: Multi-Model Agent Teams — 仿官方 agent-teams，但 teammate 可以是任意 AI CLI（CC 分身 / codex / gemini），支持 Google A2A v0.3 HTTP 协议、cmux 多窗格可视化、MCP 桥接 Claude Code。
version: 2.2.0
triggers:
  - multi-model team
  - 多模型团队
  - mmteam
  - 跨模型代理
  - 多模型协作
  - a2a
  - agent teams
---

# mmteam v2.2 — Multi-Model Agent Teams

把 **任意 AI CLI**（7 个 CC 分身 + codex + gemini，共 9 家）编排成一个可并行 / 可串行 / 可交叉审查的 team。支持两种传输层（本地文件 IPC 和 Google A2A HTTP），两种执行后端（headless 无界面 / cmux dock 可视网格），一个 MCP 桥（让 Claude Code 原生调用）。

**脚本**：
- `~/bin/mmteam` — 主命令（v1 file IPC + v2 A2A CLI）
- `~/bin/mmteam-a2a-server.py` — 每个 teammate 一个 HTTP daemon
- `~/bin/mmteam-a2a-monitor.py` — cmux 顶部监控条（事件流）
- `~/bin/mmteam-mcp.py` — stdio MCP server 暴露给 CC

**数据**：`~/.claude/teams/<team>/`

---

## 路由决策（先看这一节）

主 CC 和每个分身都同时拥有两种协作框架：**官方 agent-teams**（Claude 同家族 sidecar）+ **mmteam A2A**（跨厂商 / 跨机）。任务→框架的决策树见单独文档 [`ROUTING.md`](ROUTING.md)。速览：

```
需要多 agent？─否→ 直调
             └是→ 需要跨厂商多样性？
                 ├否→ 官方 agent-teams (TeamCreate)
                 └是→ mmteam A2A (mcp__mmteam__a2a_*)
```

**当前启用状态**：
- 主 CC：`~/.zshrc` 已 `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` ✅
- 7 家 CC 分身启动器已内置同环境变量 ✅（`kimi-code` 等可在各自家族内 TeamCreate）
- mmteam MCP 已注册 ✅

## 1. 架构全景

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code（主 CC session）                                    │
│       │                                                          │
│       ├─ 直接 Bash：mmteam a2a send ...                          │
│       └─ MCP 工具：mcp__mmteam__a2a_send({team, agent, text})    │
└────────────────────┬────────────────────────────────────────────┘
                     │  JSON-RPC 2.0 over HTTP  +  Bearer token
       ┌─────────────┼────────────────┬───────────────┐
       ▼             ▼                ▼               ▼
  ┌────────┐   ┌────────┐       ┌────────┐      ┌────────┐
  │ a2a-   │   │ a2a-   │       │ a2a-   │ ...  │ a2a-   │
  │ server │   │ server │       │ server │      │ server │
  │ :port₁ │   │ :port₂ │       │ :port₃ │      │ :portₙ │
  └───┬────┘   └───┬────┘       └───┬────┘      └───┬────┘
      │            │                │               │
      ▼            ▼                ▼               ▼
   kimi-code    glm-code         codex          gemini    ← 真实 CLI
   (backend)    (backend)       (backend)      (backend)
      │            │                │               │
      └────────────┴────────────────┴───────────────┘
                     │
                     ▼
             共享 ~/.claude/teams/<team>/
               ├── tasks.json  (task 生命周期)
               ├── results/    (artifact 落盘)
               ├── a2a-registry.json  (teammate url+token)
               └── config.json (成员清单)
```

---

## 2. 两种模式对比

| 维度 | **v1 file IPC**（`mmteam spawn`） | **v2 A2A HTTP**（`mmteam a2a spawn`）← 推荐 |
|---|---|---|
| 传输 | 文件 IPC（mailbox/inbox 轮询） | JSON-RPC over HTTP + Bearer auth |
| 异构 client | 只 mmteam CLI 自己 | 任何 A2A 兼容 client（curl、其他 CC、Mac mini） |
| 跨机 | 不支持 | ✅ `register <url> --token` |
| 发现 | 无 | Agent Card at `/.well-known/agent-card.json` |
| MCP 暴露 | 无 | ✅ `mmteam-mcp.py` |
| cmux 可视 | `--dock` 单 pane 多 tab | `--dock` **多 pane 网格**+`--monitor` 事件条 |
| 适用场景 | 纯本地简单编排 | **默认方案**，所有新用法走这个 |

---

## 3. 快速上手（A2A 模式，推荐）

### 建队 + 起队
```bash
# 3 家异构模型
mmteam create demo \
  kimi:kimi-code:kimi-k2.6-code-preview \
  gpt:codex:gpt-5.4 \
  gem:gemini:gemini-2.5-pro

# headless 模式（最快，看不到思考）
mmteam a2a spawn demo

# dock 模式（3 个 pane 并排在新 cmux workspace）
mmteam a2a spawn demo --dock

# dock + 顶部监控条（最完整可观察）
mmteam a2a spawn demo --dock --monitor
```

### 派任务 + 取结果
```bash
# 阻塞投任务（返 artifact）
mmteam a2a send demo kimi "用 Python 写快速排序"

# 并行投 3 家（同题多模型对比）
for a in kimi gpt gem; do
  mmteam a2a send demo $a "一句话解释 RAFT" &
done; wait

# 查任务状态（submitted / working / completed / failed / canceled）
mmteam a2a get demo kimi <task-id>

# 中断长任务
mmteam a2a cancel demo kimi <task-id>

# 看注册表 + 活性
mmteam a2a ls demo
```

### 收队 + 清理
```bash
mmteam a2a stop demo     # SIGTERM 所有 daemon + 关 cmux workspace
mmteam destroy demo      # 彻底删除 ~/.claude/teams/demo/
```

---

## 4. 完整命令表

### A2A 模式（v2，推荐）
| 命令 | 功能 |
|---|---|
| `mmteam a2a spawn <team> [--dock] [--monitor] [--port N]` | 启每个 teammate 的 HTTP daemon |
| `mmteam a2a stop <team>` | SIGTERM 所有 daemon + 关 cmux workspace |
| `mmteam a2a ls <team>` | 列 registry + 活性（local \| remote） |
| `mmteam a2a follow <team> <agent>` | 彩色 tail -F teammate 的 a2a 日志（实时看 CLI stdout 增量） |
| `mmteam a2a cost <team> [--since D] [--by agent\|day\|cli] [--json]` | 聚合 `cost-ledger.jsonl`：tasks / tokens / elapsed / USD |
| `mmteam a2a quota <team>` | 套餐用户视角：每 teammate 5min/1h/5h/24h 请求数 + 24h token 小计（防 Kimi Allegretto 300/5h 等上限触顶） |
| `mmteam a2a routes <team> "<text>"` | **Dry-run** 路由：预览 ask 会选谁 + 各家 score + quota，不发请求（零配额） |
| `mmteam a2a who <team>` | 一行摘要：✅/⚫ alive + 5h 使用率 + last activity ts |
| `mmteam a2a watch <team>` | 开多窗口观察台（新 cmux workspace `<team>-watch`，顶条 monitor + N pane tail log） |
| `mmteam a2a unwatch <team>` | 关观察台 |
| `mmteam a2a card <team> <agent>` | 拉 Agent Card（发现文档） |
| `mmteam a2a send <team> <agent> "<text>" [--session SID]` | 投任务，阻塞返 artifact。带 `--session` 时走多轮会话（同 SID 自动带上历史） |
| `mmteam a2a fanout <team> "<text>" [--agents a,b,c] [--judge X] [--json]` | **同题并发广播** + Jaccard 共识分 + outlier 标记 + 可选 judge 语义综合 |
| `mmteam a2a ask <team> "<text>"` | **智能路由**：按 prompt 关键词匹配 Agent Card skills，选最佳 teammate 自动 send |
| `mmteam a2a pipeline <team> "<text>" --writer X --reviewer Y --synth Z` | **3 段式**：写→审→总结串行，每阶段吸收前一阶段输出 |
| `mmteam a2a get <team> <agent> <task-id>` | 查任务状态 + 历史 + artifact |
| `mmteam a2a cancel <team> <agent> <task-id>` | 中断运行中任务 |
| `mmteam a2a register <team> <agent-id> <url> --token T` | 录入远端 teammate |
| `mmteam a2a discover <url>` | 拉任意 A2A URL 的 Agent Card 验证兼容性 |

### v1 file IPC 模式（保留兼容）
| 命令 | 功能 |
|---|---|
| `mmteam create <name> <spec>...` | 建队。spec 格式 `agent-id:cli[:model]` |
| `mmteam spawn <name> [--dock]` | v1 文件 daemon 模式（旧单 pane 多 tab） |
| `mmteam stop <name>` | 停 v1 daemon |
| `mmteam destroy <name>` | 彻底清理（同时停 a2a） |
| `mmteam status <name>` | 全景：成员 / daemon / 任务统计 |
| `mmteam tasks <name> add "desc" [--to id]` / `list` / `assign` | v1 任务管理 |
| `mmteam msg <name> --from A --to B "text"` | 两 teammate 间发消息 |
| `mmteam inbox <name> <agent>` | 查 inbox |

---

## 5. cmux dock 模式

### 布局自适应（1-6 家）
| N | 命令序列 | 可视 |
|---|---|---|
| 1 | （无 split） | 单 pane |
| 2 | `right` | 1×2 |
| 3 | `right` → `down` | 左 + 右柱分上下 |
| 4 | `right` → `down` → focus(L) → `down` | 2×2 |
| 5 | 4 + focus(L-top) → `right` | 3 列，左有 2 行 |
| 6 | 5 + `down` | 2×3 |
| ≥7 | 报错 → 建议 headless（pane 太挤不实用） |

每 team 一个独立 cmux workspace（命名 `<team>-a2a`），`a2a stop` 连带 `cmux close-workspace` 干净退。

### 监控条（`--monitor`）
顶部一条 full-width 窄 pane，跑 `mmteam-a2a-monitor.py` 实时输出：
```
═══ mmteam a2a monitor · team=demo · (q=quit s=toggle-expand c=clear) ═══
[15:45:00] user   → gem      submit  reply three words: hello    task=758e288d
[15:45:00] gem      ↻ working
[15:45:05] gem      ✓ completed   173 chars
[15:45:06] user   → kimi     submit  review: def fizz...          task=f6203...
[15:45:12] kimi     ✓ completed    80 chars
[15:45:15] user   → gem      submit  long essay                   task=2575...
[15:45:18] gem      ✗ canceled                                    task=2575...
```
- 着色：submit=绿 / working=黄 / completed=蓝 / canceled/failed=红
- 键位：`q` 退出 / `s` 切展开 artifact 预览 / `c` 清屏
- 数据源：800ms 轮询 `tasks.json`，按 task id 做状态 diff

### Artifact 提取策略（v2.2）
TUI 重绘使 cmux scrollback diff 不可靠。优先读 CLI 自己的 session JSONL：

| CLI | 日志路径 | 提取字段 |
|---|---|---|
| kimi / glm / doubao / qwen / minimax / mimo / stepfun | `~/.claude-envs/<slug>/.claude/projects/<encoded-cwd>/<uuid>.jsonl` | 末条 `type=assistant` 的 `message.content[].text` |
| codex | `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl` | 末条 `event_msg / task_complete.last_agent_message` |
| gemini | `~/.gemini/tmp/<project>/chats/session-*.json` | 末条 `type=gemini` 消息的 `content` 字段（字符串或 `[{text}]` 数组） |

Daemon log 会打 `[dock] response len=N via=log-tail` 或 `via=scrollback-diff` 便于审计。

### Dock 模式两个 backend 选择
| 场景 | 选 |
|---|---|
| 批量并行任务、只要 artifact | `headless`（默认） |
| 想 watch CLI 实时思考 + artifact 可靠 | `--dock`（CC 分身 + codex，log-tail 精确） |
| 全程观察 + 跨 teammate 事件时间线 | `--dock --monitor` |

---

## 6. MCP 桥（Claude Code 原生调用）

**设计**：A2A = agent↔agent HTTP，MCP = tool↔agent stdio。两协议互补。

`~/bin/mmteam-mcp.py` 注册在 `~/.claude.json.mcpServers.mmteam`。**重启 CC** 后可见 10 个工具：

| 工具 | 用途 |
|---|---|
| `mcp__mmteam__a2a_list_teams` | 列所有 team |
| `mcp__mmteam__a2a_spawn` | 起队（支持 `{team, dock?, monitor?}`） |
| `mcp__mmteam__a2a_stop` | 停队 |
| `mcp__mmteam__a2a_ls` | 列 registry |
| `mcp__mmteam__a2a_card` | 拉 Agent Card |
| `mcp__mmteam__a2a_send` | **投任务（主要用法）** |
| `mcp__mmteam__a2a_get` | 查任务状态 |
| `mcp__mmteam__a2a_cancel` | 取消任务 |
| `mcp__mmteam__a2a_register_remote` | 加远端 teammate |
| `mcp__mmteam__a2a_discover` | 拉远端 Agent Card |

CC 对话里可直接说"找 kimi 写 X，找 gemini 审"，Claude 会自动调 MCP 工具并发派发。

---

## 7. 远端 teammate（跨机协作）

**Mac Studio（服务端）**：
```bash
mmteam a2a spawn team1    # 暴露 http://0.0.0.0:port (或用反代把 localhost 映射出去)
jq -r '.kimi.bearer_token' ~/.claude/teams/team1/a2a-registry.json   # 拿 token
```

**Mac mini（调用端）**：
```bash
mmteam a2a register team1 kimi-studio http://studio.local:port/ --token <TOKEN>
mmteam a2a card team1 kimi-studio         # 验证连得上
mmteam a2a send team1 kimi-studio "分析 X"  # 远端 CLI 执行，本机拿 artifact
```

Registry 里 `kind="remote"` 的 teammate，`stop` 不会动远端 daemon（只影响本机 local 项）。

---

## 8. Agent Card（A2A v0.3 发现文档）

每个 teammate 启动时根据 CLI 类型自动生成 card，暴露在 `GET /.well-known/agent-card.json`（公开，无需 auth）：

```json
{
  "name": "kimi (kimi)",
  "description": "kimi-backed teammate (model=kimi-k2.6-code-preview) in mmteam 'demo'. Family: anthropic-compat.",
  "url": "http://127.0.0.1:55774/",
  "version": "1.0.0",
  "provider": {"organization": "mmteam", ...},
  "defaultInputModes": ["text/plain"],
  "defaultOutputModes": ["text/plain", "text/markdown"],
  "capabilities": {"streaming": false, "pushNotifications": false, "stateTransitionHistory": true},
  "authentication": {"schemes": ["bearer"]},
  "skills": [
    {"id": "code-execution", "name": "Code execution", ...},
    {"id": "repo-editing", ...},
    {"id": "chinese-coding", ...},
    {"id": "long-context", "description": "... Context window: 262,144 tokens.", ...}
  ]
}
```

### 按 CLI 推断的 skills 集（v2.9 按真实特性差异化）
| CLI | 上下文 | 独家 skill | 全量 skills |
|---|---|---|---|
| kimi | 262K | long-context | code-execution · repo-editing · chinese-coding · long-context |
| glm | 128K | reasoning-effort | code-execution · repo-editing · chinese-coding · reasoning-effort |
| doubao | 256K | provider-routing | code-execution · repo-editing · chinese-coding · provider-routing |
| qwen | 131K | sql-engineering | code-execution · repo-editing · chinese-coding · sql-engineering |
| minimax | 200K | fast-inference | code-execution · repo-editing · chinese-coding · fast-inference |
| mimo | 128K | experimental-model | code-execution · chinese-coding · experimental-model |
| stepfun | 65K | math-logic | code-execution · chinese-coding · reasoning-effort · math-logic |
| codex | 400K | algorithm-design · sandbox-exec | code-execution · algorithm-design · english-coding · sandbox-exec |
| gemini | 1M | doc-summary · cross-review | long-context · doc-summary · multi-file-review · cross-review |
| claude | 1M | （anthropic-native） | code-execution · repo-editing · english-coding · long-context · reasoning-effort · multi-file-review |

### `-team` 变体（v2.18 — 同家族内部 agent-teams 再综合）
在任意 CLI 名后加 `-team` 后缀（如 `kimi-code-team` / `claude-team` / `glm-code-team`），teammate 启动时会自动：
- `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
- 用包装 prompt 指示 CC：`TeamCreate` 起 2-3 个同家族 sidecar，分派子任务，收集后合成单一回答
- Agent Card 的 family 变为 `anthropic-agent-teams`，skills 首位固定 `parallel-sidecars`

适合"多视角独立推理再融合"的任务（复杂算法、需对照验证、长 spec 拆分）。每家 `-team` 变体都继承基座家族 skills（中文编码 / 长文 / SQL / 数学等）。

| 变体 | 基座 | 场景 |
|---|---|---|
| `claude-team` | claude | Claude 主家 multi-sidecar（默认首选） |
| `kimi-code-team` | kimi-code | Kimi Allegretto 套餐内多 sidecar，长文 |
| `glm-code-team` | glm-code | GLM Plan 内推理任务融合 |
| `doubao-code-team` | doubao-code | 豆包 5 档内 provider-routing 子分派 |
| `qwen-code-team` | qwen-code | 千问内 SQL 多 sidecar 交叉校对 |
| `minimax-code-team` | minimax-code | MiniMax 快推理多路汇合 |
| `mimo-code-team` | mimo-code | 小米 MiMo 实验家族内部分解 |
| `stepfun-code-team` | stepfun-code | 阶跃数学/逻辑多 sidecar 证明 |

---

## 9. 完整文件结构

```
~/.claude/teams/<team>/
├── config.json                        # 成员清单 + a2a_token（team 级 bearer）
├── tasks.json                         # {tasks: [{id, status, history, artifacts, ...}]}
├── a2a-registry.json                  # {agent: {url, bearer_token, kind: local|remote}}
├── a2a-workspace.json                 # {workspace: "workspace:N", monitor_surface: "surface:M"}（dock 模式）
├── agent-cards/<agent>.json           # 启动快照（每个 teammate 的 card）
├── <agent>.pid / .log                 # v1 file-IPC daemon
├── <agent>.a2a.pid / .a2a.log         # A2A HTTP daemon
├── <agent>.a2a.surface                # dock 模式该 teammate 所在 cmux surface ref
├── results/<task-id>-<agent>.md       # artifact 落盘（log-tail 或 scrollback 抽的响应）
└── mailbox/<agent>/{inbox,outbox}/    # v1 消息（A2A 模式下不用）
```

---

## 10. 任务生命周期

**状态机**：
```
submitted → working → completed
                   ↘ failed
                   ↘ canceled
```

**完整流程**（A2A 模式）：
1. Client POST `message/send` → server 生成 task id + 写 `submitted` 到 tasks.json
2. 立即改 `working` 并 upsert
3. 调 `BACKEND.run(task_id, prompt, log)` — headless 走 subprocess，dock 走 cmux 发送 + 等 idle + log-tail 抽响应
4. 写 `results/<task-id>-<agent>.md`
5. 改 `completed` + 挂 artifacts（TextPart + FilePart 指向落盘）
6. **Race-guard**：若同时收到 `tasks/cancel`，`CANCELED` set 生效，终态取 `canceled`（不覆盖）

**Cancel 实现**：
- Cancel 先 upsert tasks.json `canceled` + 加 `CANCELED` set，再信号 subprocess
- Headless → SIGTERM → 15s 后 SIGKILL
- Dock → 发 Escape 到 cmux pane（Agent 一般绑 esc 为中断）

---

## 11. 典型用例

### 同题多模型对比（A/B 实验）
```bash
mmteam create cmp kimi:kimi-code gpt:codex gem:gemini
mmteam a2a spawn cmp
# v2.4 新增 fanout：一条命令广播 + 结构化对比（省了手工 for + diff）
mmteam a2a fanout cmp "用 Python 实现 LRU Cache(LC 146)" --json | \
  jq -r '.[] | "=== \(.agent) ===\n\(.text[:500])\n"'
```

### 跨模型共识验证（fanout 核心价值）
```bash
# 三家投票：一致 = 高置信；分歧 = 提醒人工看
mmteam a2a fanout cmp "Is 91 a prime number? answer ONLY 'prime' or 'composite'." --json | \
  jq -r '.[] | "\(.agent): \(.text|ascii_downcase|gsub("\\s";""))"'
# → kimi: composite / gem: composite / gpt: composite → 共识 composite
```

### 流水线：写 → 审 → 总结
```bash
mmteam create pipe writer:kimi-code reviewer:gemini synth:codex
mmteam a2a spawn pipe --dock --monitor

TID=$(mmteam a2a send pipe writer "写 fizzbuzz Python" | jq -r .id)
CODE=$(cat ~/.claude/teams/pipe/results/${TID}-writer.md)

RTID=$(mmteam a2a send pipe reviewer "review: $CODE" | jq -r .id)
REVIEW=$(cat ~/.claude/teams/pipe/results/${RTID}-reviewer.md)

mmteam a2a send pipe synth "写代码: $CODE\n审查: $REVIEW\n一句话总结"
```

### 竞争假设调试（多头并行）
```bash
mmteam create debug h1:kimi-code h2:doubao-code h3:gemini h4:codex h5:qwen-code
mmteam a2a spawn debug --dock --monitor  # 5 pane 2×3 网格 + 顶条
for i in 1 2 3 4 5; do
  mmteam a2a send debug h$i "bug X 假设 $i: ..." &
done; wait
```

### 从 Claude Code 内部（MCP）
```
用户: 帮我并行问 kimi 和 gemini "什么是 BASE 原理"，然后总结差异
Claude:
  mcp__mmteam__a2a_spawn({team:"bq", dock:false})        # 建队如果不存在
  mcp__mmteam__a2a_send({team:"bq", agent:"kimi", text:"..."})
  mcp__mmteam__a2a_send({team:"bq", agent:"gem", text:"..."})
  [合成差异分析]
  mcp__mmteam__a2a_stop({team:"bq"})
```

---

## 12. 已知限制 + 故障排查

### 限制
- **串行**：每 teammate 同一时刻 1 任务（message/send 线程独占 BACKEND.run）
- **Token 明文**：落 `config.json` / `a2a-registry.json`（已 chmod 600，本地信任 OK；远端部署建议配 HTTPS + 短 TTL token）
- **dock ≤6**：7+ teammate pane 挤到不实用，强制报错建议 headless
- **gemini dock artifact 不稳**：gemini CLI 没持久化 session，只能 fallback scrollback
- **MCP 工具要重启 CC 才能生效**（第一次安装后）

### 故障排查
| 症状 | 排查路径 |
|---|---|
| `spawn` 提示 `failed to create workspace` | cmux 没开 / 权限问题 → `cmux ping` |
| teammate `[WARN] ... not registered yet` | 看 `~/.claude/teams/<t>/<a>.a2a.log` 末尾，API key 错 / endpoint 网络不通 |
| artifact 是 TUI chrome 不是响应 | 看 daemon log 的 `via=`，若是 `scrollback-diff` 说明 log-tail 没命中（gemini 正常；CC 分身异常→查 `~/.claude-envs/<slug>/.claude/projects/` 有没有 jsonl） |
| dock 模式 cmux 布局错位 | 关旧残留 workspace：`cmux list-workspaces` + `cmux close-workspace --workspace ws:N` |
| `tasks/cancel` 后 artifact 仍写入 | v2.2 已修（CANCELED set + 终态保护） |
| MCP 工具在 CC 里看不到 | 先 `python3 ~/bin/mmteam-mcp.py < /dev/null` 手测可起；检查 `~/.claude.json.mcpServers.mmteam`；重启 CC |

---

## 13. 与官方 agent-teams 对比

| 维度 | 官方 agent-teams | mmteam |
|---|---|---|
| Teammate 类型 | 仅 CC 实例 | 9 种任意 AI CLI |
| 模型 | 只能 Claude 系列 | 跨家，可混 Kimi/Codex/Gemini 等 |
| 状态 | 实验性（需 env flag） | 稳定 |
| UI | CC TUI 内嵌（Shift+Up/Down） | cmux 多 pane 并排 + 事件监控条 |
| 跨机 | 无 | ✅ A2A HTTP + 远端 register |
| 协议标准 | 专有 | Google A2A v0.3 兼容 |
| 并发 | 单 CC multiplex | 每 teammate 独立 daemon |
| Claude Code 调用 | 原生 | MCP 桥接 |

---

## 14. 演进路线

**已落地（v1 → v2.4）**：
- [x] 文件 IPC 基础架构（v1）
- [x] A2A HTTP 协议支持 / 远程 teammate（v2）
- [x] Backend 抽象（headless / cmux dock）（v2.1）
- [x] MCP 桥（CC 原生调用）（v2.1）
- [x] cmux 多 pane 网格布局（1-6）+ 监控条（v2.2）
- [x] Log-tail artifact 提取（CC 分身 + codex）（v2.2）
- [x] 官方 agent-teams 并排开启（主 CC + 7 分身，v2.3）
- [x] **Fanout 广播**（`a2a fanout`）+ **Jaccard 共识分析**（含中文 CJK bigram，v2.4）
- [x] **智能路由**（`a2a ask`，按 skill 关键词自动选 teammate，v2.4）
- [x] **Claude CLI 作为 teammate**（v2.4，`cli:claude` → `claude --bare -p`）
- [x] **流式 stdout tee 到 daemon log**（monitor 可实时看增量，v2.4）
- [x] **Claude-as-judge 综合评判**（`fanout --judge X`，语义共识 > 词元共识，v2.5）
- [x] **3 段式 pipeline**（`a2a pipeline --writer --reviewer --synth`，v2.6）
- [x] **增量输出 + 实时跟踪**（fanout/pipeline 即时 emit，`a2a follow` 彩色 tail daemon log，v2.7）
- [x] **多轮会话链**（`send --session SID`，server 侧 contextId→history 自动拼接，20 轮 cap，v2.8）
- [x] **7 家 CC 分身差异化 skill + 智能路由**（按 vault 真实特性分化，v2.9）
- [x] **Token/cost tracking**（3 家 session log 挖 usage，fanout 聚合 totals，v2.10）
- [x] **claude-team CLI 类型**（Claude+agent-teams 作为 mmteam teammate，官方 agent-teams 接入 A2A，v2.11）
- [x] **Gemini dock artifact**（发现 `~/.gemini/tmp/<proj>/chats/session-*.json`，dock 模式 gemini 不再靠 scrollback，v2.12）
- [x] **Token→USD 估算**（9 家定价表，fanout 聚合总花费 ≈$0.0230，v2.12）
- [x] **持久化成本账本 + 聚合报表**（`cost-ledger.jsonl` + `mmteam a2a cost --by agent|day|cli`，v2.13）
- [x] **套餐配额监控**（`mmteam a2a quota`，5min/1h/5h/24h 窗口计数；默认输出去除 USD 显示，留 JSON），v2.14）
- [x] **配额感知智能路由**（`ask` 对 ≥80% 打 0.5× 惩罚；`fanout` 自动跳过 ≥95%；quota 视图显示 pct + ⚠️/⛔ 符号，v2.15）
- [x] **Dry-run routes + who 状态 oneliner**（预览 + 晨检，零配额成本，v2.16）
- [x] **多窗口监控台** `watch` / `unwatch`（独立 cmux workspace，顶条事件 + N pane tail log，不依赖 dock 模式，v2.17）
- [x] **全 7 家 CC 分身 + Claude 的 agent-teams 化**（`{slug}-code-team` / `claude-team` 变体，统一 `-team` 后缀识别，内部 TeamCreate 同家族 sidecar 再综合，v2.18）

**待做**：
- [ ] SSE 流式（`message/stream`、`tasks/sendSubscribe`）— HTTP 层流
- [ ] gemini 专属 artifact 提取（目前靠 scrollback，不稳定）
- [ ] 任务依赖图（DAG 自动推进）
- [ ] Push notification webhook（远端通知回调）
- [ ] Claude-as-judge 融合（fanout 后由 Claude 做语义共识而非词元共识）
- [ ] mTLS（跨机器生产部署）

---

## 15. 信源

- 官方 agent-teams：`~/.claude/skills/agent-teams/SKILL.md`
- A2A 协议：https://a2a-protocol.org/latest/specification/
- MCP 协议：https://spec.modelcontextprotocol.io
- 配套 memory：`~/.claude/projects/-Users-leo/memory/reference_mmteam_a2a.md`
- vault 详设计：`Knowledge-Hub/Claude-Memory/a2a-multi-model-agent-teams-design.md`
