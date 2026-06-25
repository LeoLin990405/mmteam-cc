<div align="center">

[![English](https://img.shields.io/badge/Language-English-555555?style=for-the-badge)](README.md) &nbsp; [![中文](https://img.shields.io/badge/语言-中文-2ea44f?style=for-the-badge)](README.zh-CN.md)

</div>

# mmteam-cc

> Claude Code 的多模型 Agent 团队 —— 通过 Google A2A v0.3 + MCP 桥接编排 10 个 AI CLI。

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.0-green.svg)](CHANGELOG.md)
[![A2A](https://img.shields.io/badge/protocol-A2A%20v0.3-orange.svg)](https://a2a-protocol.org)
[![MCP](https://img.shields.io/badge/protocol-MCP-purple.svg)](https://spec.modelcontextprotocol.io)

---

## 这是什么?

一个 Claude Code 插件,让你**组建 AI CLI 团队**并把它们编排成 A2A 兼容的 HTTP agent。把同一个问题发给 3 个模型对比(fanout)、跨家族链式 写→审→合成(pipeline),或让每个家族内部起子 sidecar 做更深推理(`-team` 变体)。

### 10 个后端

| 后端 | CLI | 强项 |
|---|---|---|
| **Kimi** | `kimi-code` | 262K 上下文、中文编码 |
| **GLM** | `glm-code` | 推理、中文理解 |
| **Doubao** | `doubao-code` | 5 档自动路由、中文通用 |
| **Qwen** | `qwen-code` | SQL、阿里生态 |
| **MiniMax** | `minimax-code` | 快推理、低延迟 |
| **MiMo** | `mimo-code` | 实验性、1M 上下文 |
| **StepFun** | `stepfun-code` | 数学、逻辑、证明 |
| **Codex** | `codex` | GPT-5.4、算法、英文 |
| **Gemini** | `gemini` | 1M 上下文、多文件审查 |
| **Claude** | `claude` | Anthropic 原生、推理 |

每个后端都有 **`-team` 变体**(如 `kimi-code-team`),内部经 agent-teams 起 2-3 个同家族 sidecar 独立推理后合成一个最终答案。

---

## 快速开始

**A —— Marketplace 安装(5 分钟):**

```
/plugin marketplace add LeoLin990405/mmteam-cc
/plugin install mmteam@mmteam-cc
/reload-plugins
/mmteam:setup
```

**B —— 克隆 + 安装(完全控制):**

```bash
git clone https://github.com/LeoLin990405/mmteam-cc.git
cd mmteam-cc
bash install.sh          # 拷 bin 到 PATH + 注册 MCP
# 重启 Claude Code 激活 mcp__mmteam__a2a_* 工具
```

---

## 用法

```bash
/mmteam:create demo kimi:kimi-code gpt:codex gem:gemini   # 建团队
/mmteam:spawn demo                                         # 起守护(headless 最快)
/mmteam:ask demo "用 Python 实现 LRU Cache"                # 智能路由单发
/mmteam:fanout demo "91 是质数吗?只答 prime/composite" --agents kimi,gpt,gem   # 并行+共识
/mmteam:pipeline demo "做个 todo REST API" --writer kimi --reviewer gem --synth gpt  # 写→审→合成
/mmteam:send demo kimi "分析这段 500K token 日志"          # 直发某成员
/mmteam:stop demo      # 停守护留数据
/mmteam:destroy demo   # 全清
```

全部 slash 命令(create/spawn/stop/destroy/status/ask/send/fanout/pipeline/watch/unwatch/remote/setup)见 [English README](README.md#all-slash-commands)。

---

## MCP 桥接

安装后 Claude Code 可经 20+ MCP 工具原生调用(`mcp__mmteam__a2a_spawn` / `a2a_fanout` / `a2a_pipeline` / `a2a_ask` …),意味着 Claude 能在对话中**自主决定**把任务派给团队成员,无需 slash 命令。

---

## 架构

```
Claude Code(主会话)
  ├── /mmteam:* slash → mmteam-bridge.mjs → bin/mmteam CLI
  └── mcp__mmteam__a2a_*(原生 MCP)→ bin/mmteam-mcp.py(stdio JSON-RPC)
         │  JSON-RPC 2.0 over HTTP + Bearer token
       ┌─┴─┬───┬────┐
     a2a-srv … (每成员一个 HTTP 守护)
       └→ kimi-code / codex / gemini / glm-code-team(→ 2-3 sidecar 合成)
```

**协议**:Google A2A v0.3 最小子集 —— Agent Card 发现、`message/send`、`tasks/get`、`tasks/cancel`、Bearer 鉴权。`-team` 变体、跨主机成员、依赖与排错见 [English README](README.md)。

---

## 与 cn-cc 的关系

[cn-cc](https://github.com/LeoLin990405/cn-cc) 提供**单点 `/cn:*`** 把单个任务路由到国产模型后端;**mmteam-cc** 提供**多模型编排**(团队/fanout/pipeline/共识/跨主机)。二者互补,可并存:一次性国产任务 → `/cn:ask`;多模型共识或分阶段流程 → `/mmteam:fanout` / `/mmteam:pipeline`。

---

## 许可

Apache License 2.0 —— 见 [LICENSE](LICENSE)。本项目实现了 [A2A 协议](https://a2a-protocol.org) 与 [MCP](https://spec.modelcontextprotocol.io) 的线兼容子集,但与其各自组织无关联,见 [NOTICE](NOTICE)。
