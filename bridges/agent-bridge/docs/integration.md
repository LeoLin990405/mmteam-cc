# Agent Bridge Integration（opencli App adapter → /five-agents v5）

**目标**：把"扔 prompt 给某 Agent / 等他做完 / 拿 verdict"这个手工动作自动化掉。
**载体**：opencli 已经做好的 App adapter（CDP 反向控制 Codex/Cursor/ChatWise/...）+ 一层 bash wrapper。
**实测日期**：2026-05-29

---

## 1. 现状盘点（实测）

| Agent | opencli adapter | CDP 连通 | bridge 脚本 | 备注 |
|---|---|---|---|---|
| **Codex** | `opencli codex` ✓ | ✅ Connected | `~/.claude/bin/codex-bridge.sh` ✅ | 命令最齐：ask/send/new/read/export/extract-diff/history/projects |
| **Cursor** | `opencli cursor` ✓ | — 没装 | — | 命令同 Codex；如果你装 Cursor 1:1 复用 codex-bridge 改名即可 |
| **ChatWise** | `opencli chatwise` ✓ | — 没装 | — | 同上 |
| **ChatGPT-app** | `opencli chatgpt-app` ✓ | 未测 | — | 命令较少（无 export/history），但 ask/read 齐 |
| **Doubao-app** | `opencli doubao-app` ✓ | 未测 | — | 命令齐 |
| **Antigravity** | `opencli antigravity` ✓ | ❌ CDP 9234 不通 | 待配 | **异类**：无 `ask`，要 `send + watch + read` 拼凑；先要让 Antigravity 启动时开 CDP 9234 |
| **Trae** | ❌ 没原生 adapter | — | 三选一路径 | 你装的是 **TRAE SOLO**（VSCode fork），opencli 7 个 App 里没它 |
| **Coder** | 取决于具体品牌 | — | 等拍板 | 上次没确认是 Cursor / Continue / Cody / 别的 |
| **Claude** | 我自己 | — | 不需要 bridge | 我做 planner + fixer + integrator |

---

## 2. 统一 Bridge 接口（约定）

所有 IDE bridge 脚本都暴露相同的 3 个 subcommand：

```bash
<agent>-bridge.sh status                            # 检查连通性
<agent>-bridge.sh ask <text> [--timeout N]          # 同步发 + 等响应
<agent>-bridge.sh review <prompt-file> [--timeout N]  # 完整 review 闭环
```

`review` 输出 strict format（Claude parse 用）：

```
VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
ISSUES_COUNT=N
RESPONSE_FILE=/tmp/<agent>-bridge/...md
EXPORT_FILE=/tmp/<agent>-bridge/...md
---
<完整 markdown 响应>
```

任何 IDE 想接入只需：写一个 `xxx-bridge.sh` 满足这 3 个接口。

---

## 3. Codex Bridge 已实现（v1）

`~/.claude/bin/codex-bridge.sh` (121 行):

```bash
codex-bridge.sh status                       # 已实测 OK（Codex Connected）
codex-bridge.sh ask "Reply with: pong"       # 待你 "codex 空了" ack 后做最小测
codex-bridge.sh review <prompt-file>         # 完整闭环
```

**内部链路**：
```
opencli codex new                            # 开干净 thread 避免污染你别的会话
  ↓
opencli codex ask "$(cat prompt-file)" -f md # 同步阻塞 (timeout 600s 默认)
  ↓
opencli codex export -f md                   # 全 thread 存档到 /tmp/codex-bridge/
  ↓
awk 'VERDICT:' / count "Issues found"        # 解析结构化字段
  ↓
return stdout with VERDICT=xxx / ISSUES_COUNT=N / 完整响应
```

**Codex 独有杀手锏**：`opencli codex extract-diff` — 抽 Codex 给出的 code review patch，可以 `git apply` 直接打。下一版 codex-bridge.sh 加这个。

---

## 4. Antigravity Bridge 设计（待实现）

异类，因为 opencli antigravity 没 `ask` 命令：

```
opencli antigravity send "..."               # 单向发
opencli antigravity watch --until-idle 60    # 流式监听，闲置 60s 视为完成
opencli antigravity read -f md               # 抓最终输出
```

**前置**：Antigravity 启动时必须开 CDP 9234 端口。当前 opencli antigravity status 实测失败：
> "App launched but CDP not available on port 9234 after 15s"

需要查 Antigravity 启动参数是否支持 `--remote-debugging-port=9234`，或者在 settings 里开。

---

## 5. Trae Bridge 设计（待路径选择）

opencli 没 trae adapter，三条路：

| 路径 | 工作量 | 优缺 |
|---|---|---|
| **A.** 用 generic `opencli browser` + CDP（Trae 要先开 CDP 端口） | 中 | Trae SOLO 是 Electron，理论上可加 `--remote-debugging-port`；但 menu/chat 元素得自己 selector 反工程 |
| **B.** 给 OpenCLI 贡献 Trae adapter PR | 大 | 一劳永逸，但要研究 Trae 内部 DOM；这是 [TASK-2026-05-29-004 OHPM Adapter PR] 同类工作 |
| **C.** 退回手工：你扔 prompt + 复制 verdict（v4 现有方式） | 0 | 最简单，但失去 Trae 的自动化 |

---

## 6. v5 SKILL.md 改动草稿（不立刻覆盖 v4）

主要改动：

### 新增"Bridge 模式"章节

```markdown
## Bridge 模式（v5 自动化升级）

某个 Agent 装了 opencli + 有 bridge 脚本时，Claude 可以**直接同步驱动**它：

| Agent | Bridge 模式 | Fallback |
|---|---|---|
| Codex | `~/.claude/bin/codex-bridge.sh review <prompt>` | 手工扔 prompt |
| Antigravity | `~/.claude/bin/antigravity-bridge.sh review <prompt>`（待装） | 手工 |
| Trae | （待装/选） | 手工 |
| Coder | 同上 | 手工 |
| Claude | 我自己跑 | — |

**Claude 在每个 review/implement 步骤启动前**，先 `<agent>-bridge.sh status` 检查；
- 通 → 自己跑 bridge（全自动闭环）
- 不通 → 退回 v4 手工流程（你扔 prompt + 贴 verdict）
```

### NEEDS FIX 处理流程升级

```markdown
v4: Claude Edit patch → 等 Leo 重扔 review.md 给 Codex
v5: Claude Edit patch → 自己跑 codex-bridge.sh review <same-prompt> 复审
```

---

## 7. 落地路线图

| Phase | 内容 | 状态 |
|---|---|---|
| 0 | opencli 探查 + 命令矩阵 | ✅ |
| 1 | Codex bridge v1 (status/ask/review) | ✅ 脚本就绪，等 ask 实测 |
| 1.5 | Codex bridge v2: 加 extract-diff 自动打补丁 | 待 v1 实测后 |
| 2 | v5 SKILL.md 引入 "Bridge 模式" 章节 + RUN.md 模板加 bridge 决策点 | 待 Codex 实战验完 |
| 3 | Antigravity 配 CDP + 写 antigravity-bridge.sh | 待你说要用 Antigravity |
| 4 | Trae 路径决定（A/B/C 三选一） | 待你说 |
| 5 | Coder 拍板品牌 + 对应 bridge | 待你说 |
| 6 | 整合 `~/.claude/bin/agent-bridge` 统一 dispatcher | 待 ≥2 个 IDE bridge 就绪后 |

---

## 8. 关键限制 / 风险

- **opencli ask 命令是同步阻塞**：Codex review 通常 1-5 分钟，单次 Bash tool 调用最多 10 分钟。超时要拆。
- **CDP 占用**：opencli 通过 CDP 连接 App，如果你手动同时操作 Codex App，可能冲突（同一 thread 不同 source 写入）。bridge 用 `opencli codex new` 开干净 thread 缓解。
- **Codex 模型选择不可控**：bridge 不指定 model，用 Codex App 当前设置的模型。如果你想强制 GPT-5.4 而 App 设了 GPT-5-instant，结果不一样。
- **token 计费走 Codex App 账号**：opencli 只是反向驱动，token 还是 Codex 自己算。
- **Codex App 必须前台 / 至少 dock 里活着**：CDP 要求 App 进程在；Leo 关 App 后 bridge 失效。

---

Last updated: 2026-05-29 14:15
