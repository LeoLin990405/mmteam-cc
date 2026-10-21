# 5 Surface 交互设计（v5.2）

**确认日期**：2026-05-29
**目标**：让 Claude 与 Codex CLI / Codex App / Antigravity / Trae SOLO / Qoder 5 个 surface 进行同步双向交互（agent 完成后 sync return，无 polling）

## 1. Surface Inventory（侦察结果）

| # | Surface | 实际定位 | 接口类型 | opencli adapter | 启动需要 |
|---|---|---|---|---|---|
| 1 | **Codex CLI** | `/Users/leo/.npm-global/bin/codex` (codex-cli 0.132.0) | 直接进程 stdin/stdout | — | nothing |
| 2 | **Codex App** | `/Applications/Codex.app` | CDP via opencli | ✅ `codex` | App 开着（自带 CDP） |
| 3 | **Antigravity** | `/Applications/Antigravity.app` (com.google.antigravity 2.0.10) | CDP 9234 + HTTP serve :8082 | ✅ `antigravity` | `--remote-debugging-port=9234` 启动 |
| 4 | **Trae SOLO** | `/Applications/TRAE SOLO.app` (com.trae.solo.app 0.1.14, Electron) | CDP via generic browser | ❌ 没 native adapter | `--remote-debugging-port=9235` 启动 + 反工程 chat DOM |
| 5 | **Qoder CLI** | `/Users/leo/.npm-global/bin/qodercli` 0.1.46 ← AI terminal CLI（**不是** `/Users/leo/.local/bin/qoder` 那个文件打开器） | 直接进程 `qodercli -p` non-interactive | — | login 验证（首次） |
| 5b | ~~Qoder App~~ (deprecated) | `/Applications/Qoder.app` Electron GUI | CDP + 反工程 | ❌ 不接 | 既然 qodercli 够用，GUI 不接 |

**说明**：
- "Antigravity CLI" 已合并为 1 个 surface（`opencli antigravity` 就是 "Antigravity CLI"）— 见上次澄清回复 A
- Trae CLI (`/usr/local/bin/trae`) 是 VSCode 风格文件打开器，**不能推 prompt**，所以"Trae SOLO" 只走 GUI App
- Qoder CLI (`/Users/leo/.local/bin/qoder`) 同样是文件打开器，不是 AI 接口
- Trae 普通版 (`/Applications/Trae.app`) 用户选择不接 → 此设计排除

## 2. 统一接口规约（所有 surface 必须满足）

每个 surface 通过一个 bash 脚本 `~/.claude/bin/<agent>-bridge.sh` 暴露**统一三 verb**：

```bash
<agent>-bridge.sh status                           # 检查接口可用性
<agent>-bridge.sh ask <text>    [--timeout S]      # 同步发送 prompt + 等待 response
<agent>-bridge.sh review <prompt-file> [--timeout S] # 完整 review 闭环 + 解析 verdict
```

`review` 输出 strict format（Claude 直接 parse）：

```
VERDICT=ACCEPTED|NEEDS_FIX|UNKNOWN
ISSUES_COUNT=N
RESPONSE_FILE=/tmp/<agent>-bridge/...md
---
<完整 markdown 响应>
```

**核心原则**：
- agent 完成后 **sync return**（HTTP response / stdout / CDP return），不 polling
- 任何 surface 不可用，bridge 直接 die 退码非 0 → Claude 自动 fallback 到 v4 手工流程
- 不指定 model — model 由 agent 自己配置

## 3. 各 Surface 的实现路径

### 3.1 Codex CLI

**机制**：直接 fork/exec `codex exec` 命令，stdin 喂 prompt，stdout 拿 response。

```bash
# codex-cli-bridge.sh review <prompt-file>
codex exec --skip-git-repo-check -s read-only \
  "$(cat "$prompt_file")" > "$response_file"
# 解析 stdout 拿 verdict
```

**特点**：
- ✅ 最快、最直接（无 CDP / HTTP 中间层）
- ✅ codex CLI 内置同步，process exit = 完成信号
- ⚠️ 之前 Leo 反对过"Claude 自己跑 codex exec"，但本次明确纳入 5 surface → 视为通过 bridge 封装可接受
- ⚠️ 占用本机 codex CLI 配额（不是 Codex App 的）

**实现状态**：⏸ 等 Leo 确认 OK 再写

### 3.2 Codex App

**机制**：`opencli codex new + ask` 反向驱动 Codex 桌面应用。

```bash
# codex-bridge.sh review <prompt-file>     ← 已实现
opencli codex new
opencli codex ask "$(cat "$prompt_file")" -f md > "$response_file"
opencli codex export -f md > "$export_file"  # 留档
```

**特点**：
- ✅ Codex 桌面 App 自带 CDP，无需特殊启动
- ✅ ask 命令同步等响应
- ⚠️ 抢占当前 thread — bridge 用 `new` 开干净 thread 避免污染
- ⚠️ Codex App 必须前台或 dock 里活着

**实现状态**：✅ `~/.claude/bin/codex-bridge.sh` 121 行就绪、status 实测通

### 3.3 Antigravity

**机制**：`opencli antigravity serve` 启动 HTTP /v1/messages 端点；bridge 用 curl POST 同步等响应。

```bash
# antigravity-bridge.sh review <prompt-file>     ← 已实现
curl -s --max-time 600 -X POST http://localhost:8082/v1/messages \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"...\",\"max_tokens\":16384,\"messages\":[...]}" \
  | jq -r '.content[].text' > "$response_file"
```

**前置**：
1. `antigravity-launch-with-cdp.sh` → CDP 9234（要重启 Antigravity）
2. `antigravity-serve-up.sh` → HTTP daemon :8082

**特点**：
- ✅ HTTP 协议天然同步双向，response = 完成信号
- ⚠️ 占用 Antigravity（Leo 不能同时手工用同一个 App）
- ⚠️ Antigravity 没原生 ask，只能走 serve 路径

**实现状态**：✅ 3 个脚本就绪，等 Leo 跑 launcher

### 3.4 Trae SOLO

**机制**：opencli 无 native adapter → 用 **generic browser** + **反工程 chat DOM**。

启动步骤：
1. 写 `trae-solo-launch-with-cdp.sh` 杀掉现有 Trae SOLO + 用 `--remote-debugging-port=9235` 重启
2. 写 `trae-solo-bridge.sh` 通过 `opencli browser` attach 到 9235，用 CSS selector 定位 chat input / send button / response area
3. push: `opencli browser fill <chat-input-selector> "$prompt"` + `opencli browser click <send-btn-selector>`
4. wait: `opencli browser wait selector "<done-indicator>"` 或 polling DOM
5. read: `opencli browser extract <response-area-selector>`

**特点**：
- ⚠️ **反工程依赖 Trae SOLO UI 不变** — 升级可能破坏 selector
- ⚠️ "wait done" 没标准信号 → 可能仍需 polling DOM 变化（违反"同步双向"原则）
- ❌ 工作量大（要在 Trae SOLO 内手动找 selector）
- 💡 替代方案：给 OpenCLI 贡献 Trae adapter PR（一劳永逸但更慢）

**实现状态**：未开始。**建议 Phase 2 再做**（先把 Codex + Antigravity 跑通）

### 3.5 Qoder CLI（升 Phase 1）

**机制**：直接 fork/exec `qodercli -p` 非交互单 prompt 模式。

```bash
# qoder-cli-bridge.sh review <prompt-file>     ← 待写
qodercli -p "$(cat "$prompt_file")" \
  -f json \
  --max-turns 25 \
  --disallowed-tools "Edit,Write,MultiEdit,NotebookEdit" \
  > "$response_file"
```

**特点**：
- ✅ 跟 codex-cli-bridge 1:1 对称（只改底层命令）
- ✅ JSON 输出格式（`-f json`）比 markdown 更好解析
- ✅ `--disallowed-tools "Edit,Write"` = Codex 的 `-s read-only`（防 Qoder 自己改文件）
- ✅ `--max-turns 25` 限制 agent 迭代次数（防止跑飞）
- ⚠️ 首次跑需 OAuth login（`qodercli status` 看登录状态）
- ⚠️ TUI 模式（不带 `-p`）在 bash 没 TTY 时报 "open /dev/tty: device not configured" — `-p` 模式应 non-interactive 跳过 TTY

**实现状态**：等 Leo 反馈 `qodercli status` 登录情况后开写

## 4. 分阶段实施

### Phase 1 — 本周可上线（**4 surface**）

| Surface | bridge | 你要跑的命令 |
|---|---|---|
| Codex CLI | `codex-cli-bridge.sh` ✅ | — (已就绪、status 实测通) |
| Codex App | `codex-bridge.sh` ✅ | — (已就绪、status 实测通) |
| Antigravity | `antigravity-bridge.sh` + serve-up + launcher ✅ | 跑 launcher + serve-up |
| **Qoder CLI** ← 新升 | `qoder-cli-bridge.sh` 待写 | Leo 跑 `qodercli status` 反馈登录态后写 |

Phase 1 完成 → /five-agents 已能跑 80% 自动化（Codex CLI + Codex App + Qoder CLI 都是 sync 同步驱动 + Antigravity HTTP 同步）。

### Phase 2 — 后续（1 surface）

| Surface | 阻塞点 |
|---|---|
| Trae SOLO | opencli 无 native adapter；Electron CDP + 反工程 chat DOM 工作量大；或贡献 OpenCLI Trae adapter PR |

### Phase 3 — 抽象层（≥3 个 bridge 跑起来后）

写 `~/.claude/bin/agent-bridge`（dispatcher），让 Claude 调用统一接口：

```bash
agent-bridge <surface> review <prompt-file>
# 内部 dispatch:
#   codex-cli   → codex-cli-bridge.sh
#   codex-app   → codex-bridge.sh
#   antigravity → antigravity-bridge.sh
#   trae-solo   → trae-solo-bridge.sh
#   qoder       → qoder-bridge.sh
```

## 5. 失败处理 / Fallback 链

每个 surface 都遵循：

```
1. bridge status → 不通 → 退到 v4 手工（告知 Leo "扔 prompt 给 X"）
2. bridge ask 超时 → die → 退到 v4 手工
3. parse verdict UNKNOWN → 告知 Leo verdict 含糊，请人工看一眼
4. NEEDS_FIX 3 次仍失败 → ESCALATED：Claude 自己接管该 Task 实现/审查
```

## 6. v5 SKILL.md 落地点

在 SKILL.md "Bridge 自动化" 段落（v5 草稿已起）增加：

```markdown
## v5.2 Surface 矩阵

Phase 1 可用：
- Codex CLI (`codex-cli-bridge.sh`)
- Codex App (`codex-bridge.sh`)
- Antigravity (`antigravity-bridge.sh`)

Phase 2 待开：
- Trae SOLO
- Qoder

启动时自动检测每个 surface 的 bridge status，3 态机：ready / down / not_supported。
```

## 7. 风险 / 边界

| 风险 | 缓解 |
|---|---|
| Trae SOLO/Qoder DOM 反工程脆弱 | Phase 2 才做；优先看 Qoder 是否有 official API |
| Codex CLI 跑会用本机配额（vs Codex App 走桌面账号） | bridge prompt 里明示是 CLI 调用，让 Leo 知道 |
| Electron app 重启会丢用户当前 session | launcher 脚本明示警告 |
| opencli 升级可能破坏 bridge | 用 `opencli --version` 锁定测过的版本 |

---

Last updated: 2026-05-29 14:50
