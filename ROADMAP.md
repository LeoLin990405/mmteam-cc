# mmteam-cc Iteration Roadmap

> 给 Codex / 任何 AI 工程师的完整迭代方向书。
> 基线：v2.0.0 + brain/supervise commit (8712b2e)，1936L CLI，15 slash commands，20 MCP tools。

---

## 当前架构（v2.0 基线）

```
Layer 1 — Plugin Interface (Claude Code)
  15 slash commands → mmteam-bridge.mjs → bin/mmteam
  20 MCP tools → mmteam-mcp.py → bin/mmteam
  mmteam-orchestrator agent (brain mode + single dispatch)

Layer 2 — Orchestration Engine (bin/mmteam, 1936L Python)
  Lifecycle: create / spawn / stop / destroy / status
  Dispatch: send / ask / fanout / pipeline / supervise
  Observe:  watch / follow / quota / routes / who / cost
  Consensus: Jaccard + CJK bigram + --judge

Layer 3 — Per-Teammate A2A Daemons (mmteam-a2a-server.py, 839L)
  HeadlessBackend | CmuxDockBackend
  A2A v0.3: Agent Card + message/send + tasks/get + tasks/cancel
  Bearer auth, per-task subprocess isolation

Cross-cutting:
  mmteam-a2a-monitor.py (225L) — cmux 事件条
  mmteam-mcp.py (595L) — stdio MCP bridge
  install.sh / doctor.sh / register-mcp.mjs — 安装链路
```

### 已有能力

| 能力 | 实现 | 状态 |
|------|------|------|
| 10 base + 10 -team backends | create member-spec | ✅ |
| 单点路由 (ask) | keyword-skill scoring + quota penalty | ✅ |
| 并行广播 (fanout) | ThreadPoolExecutor + Jaccard consensus | ✅ |
| 串行流水 (pipeline) | writer→reviewer→synth 3-stage | ✅ |
| 自治监工 (supervise) | decompose→dispatch→cross-review→retry→synth | ✅ |
| 大脑模式 (brain) | orchestrator agent 多步决策 | ✅ |
| 跨机 (remote) | Bearer + Agent Card discover | ✅ |
| 可观察 (watch/follow) | cmux multi-pane + log tail | ✅ |
| 成本核算 (cost/quota) | per-agent ledger + 5h rolling window | ✅ |
| MCP 桥 | 20 tools stdio | ✅ |

### 已知短板（驱动下面的迭代）

| 短板 | 影响 | 目标版本 |
|------|------|---------|
| supervise 串行 dispatch | N 个子任务顺序跑，独立子任务白等 | v2.1 |
| 无 DAG 依赖 | 子任务间有先后关系无法表达 | v2.2 |
| 无 streaming | 长任务黑屏等到完才出结果 | v2.2 |
| 审查分数硬阈值 | 7/10 一刀切，不同场景需要不同标准 | v2.1 |
| 合成可能被限流 | supervise 最后一步 synth 碰 doubao 限流 | v2.1 |
| MCP 缺 supervise tool | 从 CC MCP 调不到 supervise | v2.1 |
| 无持久任务队列 | 重启后 supervise 状态丢失 | v2.3 |
| 无 Web UI | 只有 CLI + cmux 观察 | v2.4 |

---

## v2.1 — Supervise 强化（下一个 minor）

**目标**：让 supervise 从"能跑"到"好用"。预计 +300L CLI。

### 2.1.1 — 并行 dispatch

**问题**：当前 supervise 串行发 N 个子任务，独立子任务浪费等待时间。

**改动**：
- `cmd_a2a_supervise()` 里的 dispatch 循环改为 `ThreadPoolExecutor`
- 每个子任务标记 `depends_on: []`（分解器输出）
- 无依赖的子任务并行发，有依赖的等前置完成

```python
# bin/mmteam — cmd_a2a_supervise 内部
# 改前：for i, st in enumerate(subtasks): ...serial...
# 改后：
import concurrent.futures as _cf
independent = [s for s in subtasks if not s.get("depends_on")]
dependent   = [s for s in subtasks if s.get("depends_on")]
with _cf.ThreadPoolExecutor(max_workers=min(len(independent), 5)) as exe:
    futs = {exe.submit(_dispatch_and_review, name, s, alive_set): s for s in independent}
    for f in _cf.as_completed(futs):
        results.append(f.result())
# Then run dependent ones sequentially
for s in dependent:
    results.append(_dispatch_and_review(name, s, alive_set))
```

**文件**：`bin/mmteam` — `cmd_a2a_supervise` 函数

### 2.1.2 — 智能分解提示词升级

**问题**：当前分解器只输出 `agent: desc`，没有依赖关系和优先级。

**改动**：升级 `_supervise_decompose` 的 prompt，要求输出结构化 JSON：

```json
[
  {"id": 1, "agent": "kimi", "desc": "...", "depends_on": [], "priority": "high"},
  {"id": 2, "agent": "glm",  "desc": "...", "depends_on": [1], "priority": "medium"}
]
```

fallback：如果 agent 返回非 JSON，用当前的文本解析逻辑。

**文件**：`bin/mmteam` — `_supervise_decompose` 函数

### 2.1.3 — 可配置审查阈值 + 审查模板

**问题**：7/10 硬编码不灵活；审查提示词过于通用。

**改动**：
- 新增 `--review-threshold N` 参数（default 7）
- 新增 `--review-template PATH` 参数，读文件作为审查提示词模板
- 模板支持 `{writer}`, `{task}`, `{output}` 占位符

**文件**：`bin/mmteam` — `_supervise_review` + argparse

### 2.1.4 — Synth 容错 + 备选 agent

**问题**：合成步骤用 `alive[-1]`，如果该 agent 限流则整个 supervise 输出空。

**改动**：
- synth agent 优先选 quota 最低的 alive agent（不是写过子任务的 agent）
- 如果 synth 失败，fallback 到拼接模式（当前已有）
- 加 `--synth-agent` 参数允许用户指定

**文件**：`bin/mmteam` — `cmd_a2a_supervise` 合成部分

### 2.1.5 — MCP 暴露 supervise

**问题**：从 CC MCP 工具调不到 supervise。

**改动**：在 `mmteam-mcp.py` 加 `tool_a2a_supervise(args)` 函数：

```python
def tool_a2a_supervise(args):
    """Run brain loop: decompose → dispatch → cross-review → retry → synthesize."""
    cmd = ["mmteam", "a2a", "supervise", args["team"], args["text"], "--json"]
    if args.get("no_review"): cmd.append("--no-review")
    if args.get("max_retries"): cmd += ["--max-retries", str(args["max_retries"])]
    return _run_capture(cmd)
```

注册到 TOOLS dict，加 inputSchema。

**文件**：`bin/mmteam-mcp.py` — `TOOLS` dict + `tool_a2a_supervise` 函数

### 2.1.6 — Slash command 数量更新

新增的 `/mmteam:brain` 和 `/mmteam:supervise` 已有。确保 README 和 smoke test 计数从 13 → 15。

**文件**：`README.md`（commands 表）、`.github/workflows/smoke.yml`（`test "$CMDS" -ge 15`）

---

## v2.2 — DAG + Streaming

**目标**：支持子任务间的依赖图 + 实时进度推送。预计 +500L。

### 2.2.1 — DAG 任务引擎

在 `bin/mmteam` 中加 `_dag_execute(subtasks, dispatch_fn)` 引擎：

```python
from collections import defaultdict, deque

def _dag_execute(subtasks, dispatch_fn, max_parallel=5):
    """Topological sort + parallel dispatch respecting depends_on."""
    graph = {s["id"]: s for s in subtasks}
    in_degree = {s["id"]: len(s.get("depends_on", [])) for s in subtasks}
    dependents = defaultdict(list)
    for s in subtasks:
        for dep in s.get("depends_on", []):
            dependents[dep].append(s["id"])

    ready = deque(sid for sid, d in in_degree.items() if d == 0)
    results = {}

    with ThreadPoolExecutor(max_workers=max_parallel) as exe:
        futures = {}
        while ready or futures:
            while ready and len(futures) < max_parallel:
                sid = ready.popleft()
                dep_results = {d: results[d] for d in graph[sid].get("depends_on", []) if d in results}
                futures[exe.submit(dispatch_fn, graph[sid], dep_results)] = sid
            done, _ = wait(futures.keys(), return_when=FIRST_COMPLETED)
            for f in done:
                sid = futures.pop(f)
                results[sid] = f.result()
                for child in dependents[sid]:
                    in_degree[child] -= 1
                    if in_degree[child] == 0:
                        ready.append(child)
    return results
```

**替换** `cmd_a2a_supervise` 的串行循环为 `_dag_execute` 调用。

### 2.2.2 — SSE Streaming（A2A server 侧）

当前 `mmteam-a2a-server.py` 的 `message/send` 是同步阻塞。改为：

1. 新增 `tasks/sendSubscribe` JSON-RPC 方法，返回 SSE 流
2. 服务端在 subprocess 运行时，每行 stdout 作为 `StatusUpdate` 事件推
3. 客户端（CLI + MCP）通过 SSE 接收增量

**涉及文件**：
- `bin/mmteam-a2a-server.py` — 新增 SSE handler
- `bin/mmteam` — `_a2a_send_blocking` 改为可选 streaming 模式
- `bin/mmteam-mcp.py` — streaming tool variant

### 2.2.3 — Supervise 实时进度输出

当前 supervise 只在 stderr 打日志。改为：

```
[2/4] Dispatching...
  [1] ⏳ kimi: 实现核心类... (12s elapsed)
  [2] ⏳ glm:  编写测试...   (8s elapsed)
  [1] ✓ kimi: 完成 (18s, 2450 tok)
  [2] ✓ glm:  完成 (22s, 1890 tok)
  [1] 🔍 reviewing by doubao... (score: 8/10 ✓)
```

用 `\r` 覆盖行实现 spinner 效果（非 JSON 模式）。

---

## v2.3 — 持久化 + 恢复

**目标**：supervise 任务可中断恢复、历史可查、可 replay。

### 2.3.1 — Supervise 会话持久化

每次 `supervise` 运行创建 `~/.claude/teams/<team>/supervise/<session-id>.json`：

```json
{
  "id": "sv-abc123",
  "task": "原始任务",
  "status": "in_progress",
  "subtasks": [...],
  "results": [...],
  "cost": {...},
  "created": "2026-04-17T10:00:00",
  "updated": "2026-04-17T10:05:30"
}
```

### 2.3.2 — `mmteam a2a supervise --resume <session-id>`

从持久化文件恢复：跳过已完成的子任务，从上次失败的继续。

### 2.3.3 — `mmteam a2a supervise --history`

列出该 team 的所有 supervise 会话 + 状态 + 成本。

### 2.3.4 — 任务模板系统

常见任务模式（code-review, write-tests, refactor）做成模板：

```bash
mmteam a2a supervise dev --template code-review --target src/auth.py
```

模板存放在 `plugins/mmteam/templates/` 目录。

---

## v2.4 — 可观察性 + UI

### 2.4.1 — Supervise Watch Dashboard

`mmteam a2a supervise --watch` 或 `mmteam a2a watch-supervise <team> <session>`：

cmux 多 pane 布局：
```
┌──────────────────────────────┬────────────┐
│  Subtask Progress (main)     │  Cost Live │
│  [1] ✓ kimi: done           │  $0.012    │
│  [2] ⏳ glm: reviewing...   │  7 reqs    │
│  [3] ○ pending               │  1240 tok  │
├──────────────────────────────┤            │
│  Live Agent Output (follow)  │            │
│  glm> 审查结果：分数 8/10... │            │
└──────────────────────────────┴────────────┘
```

### 2.4.2 — Web Dashboard（长期目标）

独立进程跑 HTTP server，提供：
- Team 列表 + 状态
- Supervise 会话实时进度
- Cost 图表
- Agent Card 浏览器

技术栈：Python aiohttp + htmx（零 npm 依赖）。

---

## v2.5 — 高级编排模式

### 2.5.1 — MapReduce 模式

```bash
mmteam a2a mapreduce dev "分析这 20 个文件的安全风险" \
  --input-glob "src/**/*.py" \
  --map-agent kimi --reduce-agent codex
```

Map 阶段：每个文件发给 map-agent 并行分析。
Reduce 阶段：reduce-agent 汇总所有 map 输出。

### 2.5.2 — Tournament 模式

```bash
mmteam a2a tournament dev "实现 LRU Cache" --rounds 2
```

Round 1：所有 agent 各写一版。
Round 2：两两 PK，用第三方 agent 打分，淘汰劣者。
Final：最高分版本输出。

### 2.5.3 — Debate 模式

```bash
mmteam a2a debate dev "微服务 vs 单体" --pro kimi --con glm --judge codex --rounds 3
```

Pro/Con 各 N 轮论证，judge 给最终裁定。

### 2.5.4 — 自适应路由（学习型）

基于历史 cost-ledger 数据训练简单的 agent 选型模型：
- 输入：task 关键词 + 子任务类型
- 输出：最佳 agent + 预测 score
- 方法：记录每次 dispatch 的 (prompt_keywords, agent, review_score)，用 TF-IDF + logistic regression

---

## v2.6 — 安全 + 企业级

### 2.6.1 — mTLS

A2A daemon 间通信改为 mTLS。`mmteam a2a spawn --tls-cert/--tls-key`。

### 2.6.2 — RBAC

teammate 级别权限：
- read-only：只能 get/card/ls
- execute：可以 send/ask
- admin：可以 spawn/stop/destroy

### 2.6.3 — Audit Log

所有操作写入 `~/.claude/teams/<team>/audit.jsonl`：
- who (principal)
- what (method + params hash)
- when (ISO timestamp)
- result (success/fail)

---

## 实现优先级排序

```
v2.1 (2-3 天) — Supervise 强化
  ├── 2.1.1 并行 dispatch          [P0, 预计 50L]
  ├── 2.1.2 结构化分解             [P0, 预计 40L]
  ├── 2.1.3 可配置审查阈值         [P1, 预计 30L]
  ├── 2.1.4 Synth 容错             [P0, 预计 20L]
  ├── 2.1.5 MCP 暴露 supervise     [P1, 预计 40L]
  └── 2.1.6 README + CI 更新       [P1, 预计 15L]

v2.2 (1 周) — DAG + Streaming
  ├── 2.2.1 DAG 引擎               [P0, 预计 120L]
  ├── 2.2.2 SSE Streaming          [P1, 预计 150L]
  └── 2.2.3 实时进度               [P1, 预计 80L]

v2.3 (1 周) — 持久化 + 恢复
  ├── 2.3.1 会话持久化             [P0, 预计 60L]
  ├── 2.3.2 --resume               [P0, 预计 40L]
  ├── 2.3.3 --history              [P1, 预计 30L]
  └── 2.3.4 模板系统               [P2, 预计 80L]

v2.4 (2 周) — 可观察性 + UI
  ├── 2.4.1 Supervise Watch        [P1, 预计 100L]
  └── 2.4.2 Web Dashboard          [P2, 预计 500L]

v2.5 (探索) — 高级编排
  ├── 2.5.1 MapReduce              [P2, 预计 100L]
  ├── 2.5.2 Tournament             [P2, 预计 120L]
  ├── 2.5.3 Debate                 [P2, 预计 80L]
  └── 2.5.4 自适应路由             [P3, 预计 200L]

v2.6 (长期) — 安全 + 企业
  ├── 2.6.1 mTLS                   [P3]
  ├── 2.6.2 RBAC                   [P3]
  └── 2.6.3 Audit Log              [P2]
```

---

## Codex 执行指南

### 环境

```bash
cd ~/Projects/mmteam-cc
# 核心 CLI：bin/mmteam (Python 3.9+, 单文件, 无外部依赖)
# MCP server：bin/mmteam-mcp.py (Python 3.9+, 单文件)
# A2A server：bin/mmteam-a2a-server.py (Python 3.9+, 单文件)
# Bridge：plugins/mmteam/scripts/mmteam-bridge.mjs (Node 20+)
```

### 关键约束

1. **bin/ 下 4 个脚本是 vendor 快照**。修改后必须 `cp` 回 `~/bin/mmteam*` 才能本地生效，或者直接改 `~/bin/` 源再 `bash scripts/sync-from-dev.sh`。
2. **零外部依赖**。bin/ 脚本只用 Python stdlib，不准引入 pip 包。
3. **MCP 和 CLI 功能要同步**。新增 CLI subcommand 必须在 mmteam-mcp.py 加对应 tool，在 bridge.mjs 加路由。
4. **slash command 是 .md frontmatter 文件**，不是代码。每新增一个命令加一个 `plugins/mmteam/commands/<name>.md`。
5. **向后兼容**。已有的 15 个 slash command 和 20 个 MCP tool 的接口签名不能变。
6. **测试**：每个 feature commit 后跑 `python3 -m py_compile bin/*.py && node --check plugins/mmteam/scripts/*.mjs && bash -n *.sh`。

### Commit 规范

```
feat: 新功能
fix: bug 修复
docs: 文档
ci: CI/workflow
refactor: 重构（无功能变更）
```

每个 2.x.y 小项单独 commit。完成一个 minor 版本后打 tag：`git tag v2.1.0`。

### 验证清单（每个版本发布前必跑）

```bash
# 语法
for f in bin/*.py; do python3 -m py_compile "$f"; done
for f in plugins/mmteam/scripts/*.mjs; do node --check "$f"; done
for f in install.sh uninstall.sh doctor.sh scripts/sync-from-dev.sh tests/smoke/*.sh; do bash -n "$f"; done
jq empty .claude-plugin/marketplace.json package.json

# 结构
test $(ls plugins/mmteam/commands/*.md | wc -l) -ge 15

# 端到端
mmteam create test-release kimi:kimi-code glm:glm-code
mmteam a2a spawn test-release
mmteam a2a who test-release
mmteam a2a send test-release kimi "ping"
mmteam a2a supervise test-release "写一个 hello world" --no-review
mmteam a2a stop test-release
mmteam destroy test-release

# Install
bash install.sh --dry-run
bash doctor.sh
```
