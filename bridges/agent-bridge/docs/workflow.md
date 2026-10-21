# /five-agents v5 草稿 — Bridge 模式集成

**状态**：草稿（不覆盖 v4，等 Codex bridge + Antigravity bridge 实战验证后再升级 SKILL.md 主文件）
**日期**：2026-05-29

## v4 → v5 一句话变化

> v4：Leo 手动扔 prompt 给 IDE / 把 verdict 复制回 Claude
> **v5：IDE 暴露 HTTP/CDP，Claude 直接 POST/CDP 同步驱动，完成后 agent 主动 sync return**

零手工传递、零 polling。

## 与 Leo 交互的两种模式（v5.1.1）

| 时机 | 模式 | Leo 动作 |
|---|---|---|
| Step 0 计划完成 | **询问** | 看计划骨架，可打回让 Claude 改 |
| Step i 每步完成 | **通知**（一行进度） | 仅看，不需要回复，Claude 自动继续 |
| NEEDS_FIX patch | **通知** | 仅看 Claude 在 patch 什么，不需要回复 |
| Final 收尾 | **询问 → 提交方式** | repo URL 给你，你决定 push/submit |

**核心原则**：Step i 是"进度条不是问询"。Leo 看着但不必反应，Claude 串行推进。

## 进度通知格式（v5.1.1）

```
[14:00] PLAN: 4 tasks (Task A=Trae / Task B=Coder / Task C=Codex review固定 / Task D=Claude)
[14:01] ▶ Task A: dispatch to Trae (implement QuoteEngine, 7 classes)
[14:08] ← Task A: Trae returned (47s)
[14:08] ▶ Task A: review.md dispatch to Codex
[14:11] ← Task A: Codex ACCEPTED ✓ (1 round, 3 min)
[14:11] ▶ Task B: dispatch to Coder (implement MemeEngine)
[14:18] ← Task B: Coder returned (52s)
[14:18] ▶ Task B: review.md dispatch to Codex
[14:20] ← Task B: Codex NEEDS_FIX (3 issues)
[14:20]   patching: MemeEngine.py:42 — font fallback missing
[14:20]   patching: MemeEngine.py:67 — output_dir not created
[14:20]   patching: __init__.py:1 — re-export incomplete
[14:21] ▶ Task B: re-review to Codex
[14:23] ← Task B: Codex ACCEPTED ✓ (2 rounds, 5 min)
[14:23] ▶ Task C: ...
...
[14:55] ✓ ALL TASKS DONE — committing + creating LeoLin990405/nd0044-fyyur
[14:56] FINAL: https://github.com/LeoLin990405/nd0044-fyyur — ready for Udacity submit
```

格式约定：
- `▶` = Claude dispatch (出口)
- `←` = Agent 回报 (入口)
- `↻` = Claude patch (自闭环)
- `✓` = step OK
- `✗` = step failed (退回 v4 手工)

## 设计原则（不变）

- 5 Agent 仍是 IDE/CLI 名（Codex/Claude/Antigravity/Coder/Trae），不指定 model
- Codex 仍是固定 Reviewer
- NEEDS FIX 仍由 Claude 直接 Edit patch（不回 implementer 重写）
- v4 手工流程仍是 **fallback** — bridge 不通时自动回退

## v5 增加的 Bridge 层

```
┌─────────────────────────────────────────────────────────────┐
│                       Claude Code (我)                      │
│                                                             │
│   if <agent>-bridge.sh status OK:                           │
│      bash <agent>-bridge.sh review <prompt-file>   ← 自动   │
│   else:                                                     │
│      告诉 Leo："扔 <prompt-file> 给 <agent>"  ← v4 回退      │
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
  ┌─────▼─────┐ ┌────▼─────┐ ┌────▼──────┐
  │ codex-    │ │antigrav- │ │  其他     │
  │ bridge.sh │ │ity-      │ │ -bridge   │
  │           │ │bridge.sh │ │ (待加)    │
  └─────┬─────┘ └────┬─────┘ └───────────┘
        │            │
  opencli codex ask  curl POST :8082
  (CDP, 同步)        (HTTP, 同步)
        │            │
  ┌─────▼─────┐ ┌────▼──────┐
  │  Codex    │ │Antigravity│
  │ Desktop   │ │  Desktop  │
  │  App      │ │   App     │
  └───────────┘ └───────────┘
```

## v5 执行循环（与 v4 对比）

### v4 review 步骤

```
1. Claude 写 task<N>_review.md
2. 告诉 Leo："扔 task<N>_review.md 给 Codex"
3. Leo 复制 Codex 输出贴回 Claude
4. Claude parse verdict
5. NEEDS FIX → Claude Edit patch → 告诉 Leo："扔 task<N>_review.md 给 Codex 复审"（人工 loop）
```

### v5 review 步骤

```
1. Claude 写 task<N>_review.md
2. Claude 自己跑：
   if codex-bridge.sh status → OK:
     bash ~/.claude/bin/codex-bridge.sh review task<N>_review.md
   else:
     fallback v4 手工流程
3. Claude 直接读 stdout 拿 VERDICT/ISSUES_COUNT/RESPONSE_FILE
4. ACCEPTED → 进下一步（全自动）
   NEEDS FIX → Claude Edit patch → 再跑 codex-bridge.sh review（同一文件）→ 复审循环（全自动）
5. 只有最终 ACCEPTED 才给 Leo 报告 "Task N 完成"
```

**Leo 体感**：扔一个 task ID 给 Claude，回来时已经是 commit 好的代码 + 一行总结。中间不需要扔 prompt、不需要贴 verdict。

## Bridge 状态机（每个 agent）

每个 IDE 在 v5 流水线启动前自检：

```python
def agent_bridge_status(agent):
    """Returns: 'ready' / 'needs_setup' / 'not_supported' / 'down'"""
    if not exists(f"~/.claude/bin/{agent}-bridge.sh"):
        return 'not_supported'  # 该 agent 还没写 bridge，必须 v4 手工
    if subprocess(f"{agent}-bridge.sh status").rc != 0:
        return 'down'           # bridge 写了但 prerequisite 没满足
    return 'ready'

# Claude 启动协议：
for agent in plan_agents:
    s = agent_bridge_status(agent)
    if s == 'ready':
        plan.mode[agent] = 'bridge'  # 全自动
    elif s == 'down':
        print(f"[{agent}] bridge 待修：状态 down — 退回 v4 手工 (可在 RUN.md 看 prerequisite 步骤)")
        plan.mode[agent] = 'manual'
    elif s == 'not_supported':
        plan.mode[agent] = 'manual'  # 静默 fallback
```

## 当前实现矩阵

| Agent | Bridge 文件 | Prerequisite | 状态 |
|---|---|---|---|
| **Codex** | `codex-bridge.sh` | Codex App 开着 + CDP（默认自动） | ✅ ready（status 实测 Connected） |
| **Antigravity** | `antigravity-bridge.sh` + `serve-up.sh` + `launch-with-cdp.sh` | (1) launcher 跑过 → CDP 9234 (2) serve-up 跑过 → HTTP :8082 | ⏸ Leo 跑 2 个 prerequisite 后 ready |
| **Trae** | 未写 | opencli 无 native adapter | ❌ not_supported（v4 手工） |
| **Coder** | 未写（待 Leo 拍板 Coder 是哪个） | 取决于具体 IDE | ❌ not_supported |
| **Claude** | 自己 | — | ✅ 永远 ready（我自己跑） |

## v5 RUN.md 模板增加段

```markdown
## Bridge 自动化（v5 新）

本项目流水线启动时，Claude 自动检测各 Agent 的 bridge 状态：

| Agent | Bridge | 状态 | 失败时回退 |
|---|---|---|---|
| Codex | codex-bridge.sh | <ready/down/not_supported> | v4 手工 |
| Antigravity | antigravity-bridge.sh | ... | v4 手工 |
| Trae | — | not_supported | v4 手工 |

**Leo 你的最小动作**：
- bridge=ready 的 Agent → 你**什么都不用做**，Claude 自动跑全闭环
- bridge=down 的 Agent → Claude 会贴 prerequisite 命令（一行），你跑了 bridge 就 ready
- bridge=not_supported → 走 v4 手工（扔 prompt + 贴 verdict）
```

## 待办

| 项 | 状态 | 触发条件 |
|---|---|---|
| Codex bridge ask 最小实测 | ⏸ | Leo 说"codex 空了" |
| Antigravity launcher + serve-up + bridge 实测 | ⏸ | Leo 跑 launcher（会杀 antigravity 进程）|
| Codex bridge v2：加 extract-diff 自动 git apply | 待 | Codex bridge v1 实战通后 |
| Trae bridge 路径决定 | 待 | Leo 说要 Trae 自动化时 |
| Coder bridge | 待 | Leo 拍板 Coder 是哪个 IDE |
| **v5 SKILL.md 主文件 overwrite v4** | 待 | Codex + Antigravity bridge 都实战通过 1 个项目 |
| 统一 dispatcher `~/.claude/bin/agent-bridge` | 待 | ≥2 个 IDE bridge 就绪、确认接口稳定后再抽象 |

## 风险 / 边界

- **opencli daemon 不稳定** → bridge 调用 `opencli xxx status` 失败 → 自动 fallback v4
- **Codex App 关掉** → CDP 断 → bridge 自动 fallback v4
- **Antigravity serve --timeout 默认 120s**（脚本里我改成 600s）→ 长 review 可能爆，可以传 `--timeout 1200` 给 serve-up
- **HTTP timeout / 网络** → curl --max-time 控；超时 die，Claude 看到 die 退回 v4
- **CDP / serve 占资源** → 占着不放；建议 v5 SKILL.md 流程结束自动 `serve-up.sh stop` 释放

## 一句话总结 v4 → v5

> v4：流水线还在你（Leo）和 Claude 之间靠人工传递信息
> v5：流水线只剩两端 — 你给一个任务 / Claude 给一个完成报告，中间全自动
> **v5.1.1：中间不是黑箱 — 每一步 dispatch/return/patch 都打一行进度通知给你看，但不要求你反应**

---

Last updated: 2026-05-29 14:35
