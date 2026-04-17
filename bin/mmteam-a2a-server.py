#!/usr/bin/env python3
"""
mmteam-a2a-server — A2A-compliant HTTP daemon, one per teammate.

Spec: https://a2a-protocol.org/v0.3.0/specification/
Minimal subset implemented:
  - GET  /.well-known/agent-card.json      (discovery)
  - POST /                                 (JSON-RPC 2.0)
      method=message/send                  (blocking task dispatch)
      method=tasks/get                     (status + artifacts)
      method=tasks/cancel                  (SIGTERM → SIGKILL)
  - Bearer-token auth on POST (GET card is public)

Usage:
  mmteam-a2a-server.py --team <name> --agent <id> [--port N] [--host 127.0.0.1]
  (Reads team config from ~/.claude/teams/<name>/config.json)
"""
import argparse, json, os, sys, time, uuid, subprocess, signal, threading
import socket, atexit, importlib.util, importlib.machinery
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path.home() / ".claude" / "teams"

# ────── import helpers from ~/bin/mmteam (no .py extension → explicit loader) ──────
def _load_mmteam():
    path = str(Path.home() / "bin" / "mmteam")
    loader = importlib.machinery.SourceFileLoader("mmteam_mod", path)
    spec = importlib.util.spec_from_loader("mmteam_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod
_mm = None
def mm():
    global _mm
    if _mm is None: _mm = _load_mmteam()
    return _mm

# ────── Agent Card generator (Phase 1a) ──────
def _slug_of(cli: str) -> str:
    """kimi-code → kimi ; cc-kimi → kimi ; codex → codex ; gemini → gemini ;
    claude-team → claude ; kimi-code-team → kimi (strips -team then -code)."""
    s = cli
    if s.endswith("-team"): s = s[:-5]
    if s.startswith("cc-"): return s[3:]
    if s.endswith("-code"): return s[:-5]
    return s

def _is_team_variant(cli: str) -> bool:
    """True if this CLI should run with agent-teams enabled + TeamCreate prompt wrap."""
    return cli.endswith("-team")

def _base_cli(cli: str) -> str:
    """claude-team → claude ; kimi-code-team → kimi-code ; codex → codex."""
    return cli[:-5] if cli.endswith("-team") else cli

SKILL_CATALOG = {
    # Common primitives reused across clones
    "code-execution":   {"name": "Code execution",     "description": "Reads, writes, and runs code in headless mode."},
    "repo-editing":     {"name": "Repository editing", "description": "Multi-file edits with permission controls."},
    "chinese-coding":   {"name": "Chinese-language coding", "description": "Handles Chinese comments, docs, and identifiers."},
    "english-coding":   {"name": "English-language coding", "description": "Primary English prompting target."},
    "long-context":     {"name": "Long-context analysis",   "description": "Handles very long inputs without truncation."},
    "cross-review":     {"name": "Cross-model review",      "description": "Reviews output from another model critically."},
    "algorithm-design": {"name": "Algorithm design",        "description": "Derives and proves correct-by-construction solutions."},
    "sandbox-exec":     {"name": "Sandboxed workspace write","description": "Executes with write access to a single workspace."},
    "doc-summary":      {"name": "Document summarization",  "description": "Condenses very long documents."},
    "multi-file-review":{"name": "Multi-file review",       "description": "Reasons across many files at once."},
    "reasoning-effort": {"name": "Tunable reasoning effort","description": "Supports explicit effort/thinking budget levels."},
    # v2.9: differentiated CC-clone skills
    "sql-engineering":  {"name": "SQL engineering",         "description": "Writes optimized SQL for Doris/ADB/PolarDB/MySQL, handles joins/CTEs/windowing."},
    "fast-inference":   {"name": "Fast inference",          "description": "Low-latency responses; supports high-speed model tiers (suited to first-token-time-sensitive tasks)."},
    "math-logic":       {"name": "Math & logic reasoning",  "description": "Proofs, derivations, theorem-style reasoning; thinking mode enabled by default."},
    "experimental-model":{"name":"Experimental model",      "description": "Newer/exploratory model family — use when evaluating novel capabilities."},
    "provider-routing": {"name": "Automatic provider routing","description": "Backend auto-selects model tier (code/pro/lite) based on task complexity."},
    # v2.11: agent-teams orchestrator teammate
    "parallel-sidecars":{"name": "Parallel Claude sidecars","description": "Spawns Claude sidecars in parallel via official TeamCreate/SendMessage, then synthesizes."},
}

# v2.13: Pricing table (duplicated from mmteam CLI for in-server cost calculation).
# Kept in sync with ~/bin/mmteam's _PRICING.
_PRICING = {
    "claude":  {"in": 3.0, "out": 15.0, "cached": 0.30},
    "codex":   {"in": 1.25, "out": 10.0, "cached": 0.13},
    "gemini":  {"in": 1.25, "out": 10.0, "cached": 0.31},
    "kimi":    {"in": 0.15, "out": 2.50, "cached": 0.02},
    "glm":     {"in": 0.10, "out": 1.00, "cached": 0.01},
    "doubao":  {"in": 0.10, "out": 1.00, "cached": 0.01},
    "qwen":    {"in": 0.10, "out": 1.00, "cached": 0.01},
    "minimax": {"in": 0.10, "out": 1.00, "cached": 0.01},
    "mimo":    {"in": 0.10, "out": 1.00, "cached": 0.01},
    "stepfun": {"in": 0.10, "out": 1.00, "cached": 0.01},
    "claude-team": {"in": 3.0, "out": 15.0, "cached": 0.30},
}

def _cost_usd(usage: dict, slug: str) -> float:
    p = _PRICING.get(slug)
    if not p or not usage: return 0.0
    cached = usage.get("cached", 0) or 0
    inp = max(0, (usage.get("input", 0) or 0) - cached)
    out = usage.get("output", 0) or 0
    return round((inp * p["in"] + cached * p["cached"] + out * p["out"]) / 1_000_000, 6)

# Per-CLI skill set + metadata. Slug → (skills[], ctx_tokens, capabilities)
# v2.9: skills differentiated by real vault memory (cc-*-rebrand.md) — not all the same
CLI_PROFILES = {
    # Moonshot K2.6-code, Allegretto 套餐, 262K 最长上下文 in family
    "kimi":    {"skills": ["code-execution","repo-editing","chinese-coding","long-context"],                     "ctx": 262144,  "family": "anthropic-compat"},
    # 智谱 GLM-4.7/5.1, reasoning-optimized family
    "glm":     {"skills": ["code-execution","repo-editing","chinese-coding","reasoning-effort"],                 "ctx": 128000,  "family": "anthropic-compat"},
    # 火山方舟 ark-code-latest 自动 5 档真分路由 (code/pro/lite/auto)
    "doubao":  {"skills": ["code-execution","repo-editing","chinese-coding","provider-routing"],                 "ctx": 256000,  "family": "anthropic-compat"},
    # 阿里通义 qwen3-coder, DashScope 百炼, 阿里生态/SQL 专长
    "qwen":    {"skills": ["code-execution","repo-editing","chinese-coding","sql-engineering"],                  "ctx": 131072,  "family": "anthropic-compat"},
    # MiniMax M2.7 + M2.7-highspeed 档，首字时延最短
    "minimax": {"skills": ["code-execution","repo-editing","chinese-coding","fast-inference"],                   "ctx": 200000,  "family": "anthropic-compat"},
    # 小米 mimo-v2-pro/omni, 实验性探索模型
    "mimo":    {"skills": ["code-execution","chinese-coding","experimental-model"],                              "ctx": 128000,  "family": "anthropic-compat"},
    # 阶跃星辰 step-3.5-flash, thinking 默认开, 数学/逻辑
    "stepfun": {"skills": ["code-execution","chinese-coding","reasoning-effort","math-logic"],                   "ctx": 65536,   "family": "anthropic-compat"},
    "codex":   {"skills": ["code-execution","algorithm-design","english-coding","sandbox-exec"],                 "ctx": 400000,  "family": "openai-codex"},
    "gemini":  {"skills": ["long-context","doc-summary","multi-file-review","cross-review"],                     "ctx": 1000000, "family": "google-gemini"},
    "claude":  {"skills": ["code-execution","repo-editing","english-coding","long-context","reasoning-effort","multi-file-review"], "ctx": 1000000, "family": "anthropic-native"},
    # v2.11/v2.18: *-team variants run the same base CLI but with agent-teams enabled
    # + TeamCreate prompt wrap. Each spawns same-family sidecars for parallel reasoning.
    "claude-team":       {"skills": ["parallel-sidecars","code-execution","repo-editing","long-context","reasoning-effort","multi-file-review"], "ctx": 1000000, "family": "anthropic-agent-teams"},
    "kimi-code-team":    {"skills": ["parallel-sidecars","code-execution","repo-editing","chinese-coding","long-context"],                       "ctx": 262144,  "family": "anthropic-agent-teams"},
    "glm-code-team":     {"skills": ["parallel-sidecars","code-execution","repo-editing","chinese-coding","reasoning-effort"],                   "ctx": 128000,  "family": "anthropic-agent-teams"},
    "doubao-code-team":  {"skills": ["parallel-sidecars","code-execution","repo-editing","chinese-coding","provider-routing"],                   "ctx": 256000,  "family": "anthropic-agent-teams"},
    "qwen-code-team":    {"skills": ["parallel-sidecars","code-execution","repo-editing","chinese-coding","sql-engineering"],                    "ctx": 131072,  "family": "anthropic-agent-teams"},
    "minimax-code-team": {"skills": ["parallel-sidecars","code-execution","repo-editing","chinese-coding","fast-inference"],                     "ctx": 200000,  "family": "anthropic-agent-teams"},
    "mimo-code-team":    {"skills": ["parallel-sidecars","code-execution","chinese-coding","experimental-model"],                                "ctx": 128000,  "family": "anthropic-agent-teams"},
    "stepfun-code-team": {"skills": ["parallel-sidecars","code-execution","chinese-coding","reasoning-effort","math-logic"],                     "ctx": 65536,   "family": "anthropic-agent-teams"},
}

def _skill_entry(sid: str, ctx_tokens: int) -> dict:
    base = SKILL_CATALOG[sid]
    out = {
        "id": sid,
        "name": base["name"],
        "description": base["description"],
        "inputModes":  ["text/plain"],
        "outputModes": ["text/plain", "text/markdown"],
    }
    if sid == "long-context":
        out["description"] = f"{base['description']} Context window: {ctx_tokens:,} tokens."
    return out

def agent_card_for(agent_id: str, cli: str, model: str, url: str, team: str) -> dict:
    """Pure function — builds A2A v0.3 Agent Card for a teammate.
    url includes scheme+host+port (e.g. http://127.0.0.1:19010/).
    v2.18: lookup CLI_PROFILES by full cli first (for -team variants), then fall back to slug.
    """
    # Prefer exact-cli match (e.g. 'kimi-code-team'); fall back to slug ('kimi')
    profile = CLI_PROFILES.get(cli) or CLI_PROFILES.get(_slug_of(cli)) or \
              {"skills": ["code-execution"], "ctx": 32768, "family": "unknown"}
    slug = _slug_of(cli)
    variant = " (agent-teams)" if _is_team_variant(cli) else ""
    desc = f"{slug}-backed teammate{variant} (model={model or 'default'}) in mmteam '{team}'. Family: {profile['family']}."
    return {
        "name": f"{agent_id} ({slug})",
        "description": desc,
        "url": url,
        "version": "1.0.0",
        "provider": {"organization": "mmteam", "url": "https://github.com/LeoLin990405"},
        "defaultInputModes":  ["text/plain"],
        "defaultOutputModes": ["text/plain", "text/markdown"],
        "capabilities": {
            "streaming": False,
            "pushNotifications": False,
            "stateTransitionHistory": True,
        },
        "authentication": {"schemes": ["bearer"]},
        "skills": [_skill_entry(sid, profile["ctx"]) for sid in profile["skills"]],
    }

# ────── Task store (shared tasks.json + in-memory subprocess map) ──────
TASK_LOCK = threading.Lock()
RUNNING: dict[str, subprocess.Popen] = {}   # task_id → Popen (headless backend cancel)
CANCELED: set[str] = set()                   # task ids marked canceled while in-flight
BACKEND = None                               # Backend instance (set by main())
# Session chain: contextId → list of {role, text} turns (chronological)
SESSIONS: dict[str, list] = {}
SESSION_LOCK = threading.Lock()
SESSION_MAX_TURNS = 20                       # cap per session to avoid runaway prompt size

def _tasks_file(team): return ROOT / team / "tasks.json"
def _results_dir(team): return ROOT / team / "results"
def _log_dir(team): return ROOT / team

# tasks.json shape (shared with mmteam v1): {"tasks": [ {...}, ... ]}
def _load_tasks(team):
    return mm().load_json(_tasks_file(team), {"tasks": []}).get("tasks", [])
def _save_tasks(team, tlist):
    mm().save_json(_tasks_file(team), {"tasks": tlist})

def _upsert_task(team, task):
    with TASK_LOCK:
        tlist = _load_tasks(team)
        for i, t in enumerate(tlist):
            if t.get("id") == task["id"]: tlist[i] = task; break
        else: tlist.append(task)
        _save_tasks(team, tlist)

def _get_task(team, tid):
    with TASK_LOCK:
        for t in _load_tasks(team):
            if t.get("id") == tid: return t
    return None

# ────── JSON-RPC handlers (Phase 1c/1d) ──────
def _parts_to_prompt(parts: list) -> str:
    """Extract TextParts from a Message into a single prompt string."""
    chunks = []
    for p in parts or []:
        kind = p.get("kind") or p.get("type")
        if kind == "text": chunks.append(p.get("text", ""))
        elif kind == "file":
            uri = p.get("file", {}).get("uri") or p.get("uri")
            if uri: chunks.append(f"[file: {uri}]")
        elif kind == "data":
            chunks.append(f"[data: {json.dumps(p.get('data'), ensure_ascii=False)[:500]}]")
    return "\n\n".join(chunks)

def _extract_usage(cli: str, since_ts: float, log_fp=None) -> dict:
    """Mine token usage from the CLI's on-disk session log. Works for both headless
    and dock backends (same persistent logs either way). Returns {input, output,
    cached, reasoning, total, source} or {} on failure."""
    slug = _slug_of(cli)
    try:
        # CC clones — ~/.claude-envs/<slug>/.claude/projects/*/<uuid>.jsonl
        if cli.endswith("-code") or cli.startswith("cc-"):
            proj = Path.home() / ".claude-envs" / slug / ".claude" / "projects"
            if not proj.exists(): return {}
            cands = [f for f in proj.rglob("*.jsonl") if f.stat().st_mtime > since_ts - 5]
            if not cands: return {}
            latest = max(cands, key=lambda f: f.stat().st_mtime)
            last_usage = None
            for line in latest.read_text().splitlines():
                try: d = json.loads(line)
                except Exception: continue
                if d.get("type") != "assistant": continue
                u = (d.get("message") or {}).get("usage")
                if u: last_usage = u
            if not last_usage: return {}
            return {
                "input": last_usage.get("input_tokens", 0),
                "output": last_usage.get("output_tokens", 0),
                "cached": (last_usage.get("cache_read_input_tokens", 0) +
                           last_usage.get("cache_creation_input_tokens", 0)),
                "total": last_usage.get("input_tokens", 0) + last_usage.get("output_tokens", 0),
                "source": f"cc-clone://{slug}",
            }
        # Codex — ~/.codex/sessions/<Y/M/D>/rollout-*.jsonl
        if cli == "codex":
            from datetime import datetime as _dt
            d_str = _dt.now().strftime("%Y/%m/%d")
            sdir = Path.home() / ".codex" / "sessions" / d_str
            if not sdir.exists(): return {}
            cands = [f for f in sdir.glob("*.jsonl") if f.stat().st_mtime > since_ts - 5]
            if not cands: return {}
            latest = max(cands, key=lambda f: f.stat().st_mtime)
            last_u = None
            for line in latest.read_text().splitlines():
                try: d = json.loads(line)
                except Exception: continue
                p = d.get("payload") or {}
                if d.get("type") == "event_msg" and p.get("type") == "token_count":
                    info = p.get("info") or {}
                    ttu = info.get("total_token_usage") or {}
                    if ttu: last_u = ttu
            if not last_u: return {}
            return {
                "input": last_u.get("input_tokens", 0),
                "output": last_u.get("output_tokens", 0),
                "cached": last_u.get("cached_input_tokens", 0),
                "reasoning": last_u.get("reasoning_output_tokens", 0),
                "total": last_u.get("total_tokens", 0),
                "source": "codex",
            }
        # Gemini — ~/.gemini/tmp/<project>/chats/session-*.json
        if cli == "gemini":
            gdir = Path.home() / ".gemini" / "tmp"
            if not gdir.exists(): return {}
            cands = list(gdir.rglob("session-*.json"))
            cands = [f for f in cands if f.stat().st_mtime > since_ts - 5]
            if not cands: return {}
            latest = max(cands, key=lambda f: f.stat().st_mtime)
            sess = json.loads(latest.read_text())
            # Find last gemini-type message with tokens
            last_t = None
            for m in sess.get("messages", []):
                if m.get("type") == "gemini" and m.get("tokens"):
                    last_t = m["tokens"]
            if not last_t: return {}
            return {
                "input": last_t.get("input", 0),
                "output": last_t.get("output", 0),
                "cached": last_t.get("cached", 0),
                "reasoning": last_t.get("thoughts", 0),
                "total": last_t.get("total", 0),
                "source": "gemini",
            }
    except Exception as e:
        if log_fp: log_fp.write(f"[usage] extract error: {e}\n")
    return {}

def _rpc_message_send(team, agent, cli, model, params):
    msg = params.get("message") or {}
    user_prompt = _parts_to_prompt(msg.get("parts", []))
    if not user_prompt:
        raise ValueError("message has no text parts")
    task_id = str(uuid.uuid4())
    context_id = msg.get("contextId") or str(uuid.uuid4())

    # Session chain: if contextId matches an existing session, prepend history.
    # This lets clients do multi-turn conversations by reusing contextId.
    with SESSION_LOCK:
        history = list(SESSIONS.get(context_id, []))
    if history:
        chat_log = "\n\n".join(f"[{t['role']}] {t['text']}" for t in history[-SESSION_MAX_TURNS:])
        prompt = (f"以下是之前的对话（请保持上下文一致）：\n\n{chat_log}\n\n"
                  f"[user] {user_prompt}")
    else:
        prompt = user_prompt

    task = {
        "id": task_id, "contextId": context_id, "kind": "task",
        "status": {"state": "submitted", "timestamp": mm().now()},
        "history": [dict(msg, messageId=msg.get("messageId") or str(uuid.uuid4()), taskId=task_id)],
        "artifacts": [],
        "_agent": agent, "_cli": cli, "_model": model, "_team": team,
        "_session_turns_before": len(history),
    }
    _upsert_task(team, task)
    task["status"] = {"state": "working", "timestamp": mm().now()}
    _upsert_task(team, task)

    log_path = _log_dir(team) / f"{agent}.a2a.log"
    result_path = _results_dir(team) / f"{task_id}-{agent}.md"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    run_started_at = time.time()
    try:
        with open(log_path, "a") as lf:
            lf.write(f"\n--- {mm().now()} task={task_id} via {BACKEND.__class__.__name__} ---\n")
            lf.flush()
            stdout = BACKEND.run(task_id, prompt, lf)
        result_path.write_text(stdout)
        # Mine token usage from the CLI's own session log (v2.10 cost tracking)
        usage = _extract_usage(cli, run_started_at)
        elapsed = round(time.time() - run_started_at, 2)
        artifact = {
            "artifactId": str(uuid.uuid4()),
            "name": f"{agent}-{task_id[:8]}",
            "parts": [
                {"kind": "text", "text": stdout},
                {"kind": "file", "file": {"name": result_path.name, "uri": f"file://{result_path}", "mimeType": "text/markdown"}},
            ],
            "metadata": {"usage": usage, "elapsed_s": elapsed},
        }
        task["artifacts"] = [artifact]
        task["usage"] = usage
        task["elapsed_s"] = elapsed
        task["status"] = {"state": "completed", "timestamp": mm().now()}
        # v2.13: Append to persistent cost ledger for later aggregation
        try:
            slug = _slug_of(cli)
            cost = _cost_usd(usage, slug)
            ledger_path = ROOT / team / "cost-ledger.jsonl"
            entry = {
                "ts": mm().now(), "task_id": task_id, "agent": agent, "cli": cli,
                "slug": slug, "usage": usage, "cost_usd": cost, "elapsed_s": elapsed,
                "backend": BACKEND.__class__.__name__,
            }
            with open(ledger_path, "a") as lf:
                lf.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except Exception as _le:
            sys.stderr.write(f"[ledger] warn: {_le}\n")
        # Append user prompt + assistant reply to session (for next turn chaining)
        with SESSION_LOCK:
            SESSIONS.setdefault(context_id, []).extend([
                {"role": "user", "text": user_prompt},
                {"role": "assistant", "text": stdout},
            ])
            # Cap history size
            if len(SESSIONS[context_id]) > SESSION_MAX_TURNS * 2:
                SESSIONS[context_id] = SESSIONS[context_id][-SESSION_MAX_TURNS*2:]
    except subprocess.TimeoutExpired:
        task["status"] = {"state": "failed", "timestamp": mm().now(), "message": "timeout"}
    except Exception as e:
        task["status"] = {"state": "failed", "timestamp": mm().now(), "message": str(e)}
    finally:
        RUNNING.pop(task_id, None)
    # Race-guard: if tasks/cancel marked this task in-flight, honor that terminal state.
    if task_id in CANCELED:
        CANCELED.discard(task_id)
        latest = _get_task(team, task_id)
        if latest: return latest
    _upsert_task(team, task)
    return task

# ────── Backend abstraction (Phase 2a: headless vs cmux-dock) ──────
class Backend:
    """Strategy for running a CLI-backed teammate. Two implementations:
    HeadlessBackend — spawn a fresh subprocess per task (stateless, fast, no UI).
    CmuxDockBackend — keep one long-lived cmux tab with CLI in TUI mode; feed prompts by
                      keyboard simulation and extract responses from scrollback (visual, stateful).
    """
    def __init__(self, agent, cli, model, team, log_fp):
        self.agent, self.cli, self.model, self.team, self.log_fp = agent, cli, model, team, log_fp
    def startup(self): pass
    def run(self, task_id: str, prompt: str, log_fp) -> str: raise NotImplementedError
    def cancel(self, task_id: str): pass
    def shutdown(self): pass

class HeadlessBackend(Backend):
    """Original mode — fresh subprocess per task."""
    def run(self, task_id: str, prompt: str, log_fp) -> str:
        import tempfile
        env = os.environ.copy()
        slug = _slug_of(self.cli)
        if self.cli.startswith("cc-") or self.cli.endswith("-code"):
            if self.model: env[f"{slug.upper()}_MODEL"] = self.model
            cmd = [self.cli, "--permission-mode", "acceptEdits", "-p", prompt]
            p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        elif self.cli == "codex":
            cmd = ["codex", "exec", "--skip-git-repo-check", "--sandbox", "workspace-write"]
            if self.model: cmd += ["-c", f'model="{self.model}"']
            cmd.append(prompt)
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        elif self.cli == "gemini":
            cmd = ["gemini"]
            if self.model: cmd += ["-m", self.model]
            with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
                f.write(prompt); f.flush(); pfile = f.name
            fstdin = open(pfile)
            p = subprocess.Popen(cmd, stdin=fstdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        elif self.cli == "claude":
            # Official Anthropic CLI as a teammate. --bare strips hooks/skills for fast response.
            cmd = ["claude", "--bare", "--permission-mode", "acceptEdits", "-p", prompt]
            if self.model: cmd += ["--model", self.model]
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        elif _is_team_variant(self.cli):
            # v2.18: any `-team` variant (claude-team, kimi-code-team, glm-code-team, etc.)
            # — run the base CLI with agent-teams enabled + TeamCreate prompt wrap so the
            # teammate internally spawns same-family sidecars and synthesizes.
            base = _base_cli(self.cli)
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
            wrapped = (
                "You have TeamCreate/SendMessage tools available (agent-teams mode). "
                "For the task below: (1) spawn 2-3 same-family sidecars with TeamCreate, "
                "(2) give each a focused subtask via SendMessage, "
                "(3) collect their responses, (4) synthesize a single final answer. "
                "Output ONLY the final synthesis — not intermediate sidecar messages.\n\n"
                f"Task: {prompt}"
            )
            if base == "claude":
                cmd = ["claude", "--permission-mode", "acceptEdits", "-p", wrapped]
                if self.model: cmd += ["--model", self.model]
            elif base.endswith("-code") or base.startswith("cc-"):
                slug = base[3:] if base.startswith("cc-") else base[:-5]
                if self.model: env[f"{slug.upper()}_MODEL"] = self.model
                cmd = [base, "--permission-mode", "acceptEdits", "-p", wrapped]
            else:
                raise ValueError(f"unknown base for team variant: {self.cli}")
            p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        else:
            raise ValueError(f"unknown cli: {self.cli}")
        RUNNING[task_id] = p
        # Stream stdout line-by-line so the monitor pane / log can show progress as CLI runs.
        # Threaded stderr collector avoids deadlock on full pipes.
        stdout_chunks = []; stderr_chunks = []
        def _collect_stderr():
            try:
                for line in iter(p.stderr.readline, ""):
                    if not line: break
                    stderr_chunks.append(line)
            except Exception: pass
        t_err = threading.Thread(target=_collect_stderr, daemon=True); t_err.start()
        try:
            deadline = time.time() + 1800
            while True:
                if time.time() > deadline:
                    p.kill(); raise subprocess.TimeoutExpired(self.cli, 1800)
                line = p.stdout.readline()
                if not line:
                    if p.poll() is not None: break
                    time.sleep(0.02); continue
                stdout_chunks.append(line)
                log_fp.write(line); log_fp.flush()
            p.wait()
        except subprocess.TimeoutExpired:
            try: p.kill()
            except Exception: pass
            raise
        t_err.join(timeout=2)
        out = "".join(stdout_chunks)
        err = "".join(stderr_chunks)
        if p.returncode:
            log_fp.write(f"\n[stderr]\n{err[:2000]}\n"); log_fp.flush()
            return out + f"\n\n[stderr]\n{err[:2000]}"
        return out

    def cancel(self, task_id: str):
        p = RUNNING.get(task_id)
        if p and p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try: p.wait(timeout=15)
            except subprocess.TimeoutExpired: p.kill()

class CmuxDockBackend(Backend):
    """Persistent cmux tab per teammate. Launches CLI TUI once at startup, feeds each
    prompt via keyboard simulation, extracts response diff from scrollback. User sees
    live thinking. Model session persists across tasks (saves context + tokens)."""
    def __init__(self, agent, cli, model, team, log_fp):
        super().__init__(agent, cli, model, team, log_fp)
        self._surf = None
        self._mm_lock = threading.Lock()  # serialize prompts to one tab

    def startup(self):
        m = mm()
        # Prefer parent-assigned surface from multi-pane grid spawn.
        # Fallback: legacy single-pane-multi-tab mode.
        env_ws = os.environ.get("A2A_CMUX_WORKSPACE", "")
        env_surf = os.environ.get("A2A_CMUX_SURFACE", "")
        if env_ws and env_surf:
            self._surf = env_surf
            self._ws = env_ws
            # Ensure all mmteam cmux_* calls (launch_cli_in_tab / send_prompt_to_tab /
            # wait_idle / cmux_close) default to our workspace, not the caller's.
            os.environ["CMUX_WORKSPACE_ID"] = env_ws
            self.log_fp.write(f"[dock] using parent-assigned surface={env_surf} workspace={env_ws}\n")
        else:
            pane = m.cmux_dock_pane()
            self._surf = m.cmux_new_surface(pane, f"{self.team}/{self.agent}")
            self._ws = ""
            self.log_fp.write(f"[dock] legacy mode: created surface={self._surf} pane={pane}\n")
        (ROOT / self.team / f"{self.agent}.a2a.surface").write_text(self._surf)
        self.log_fp.flush()
        m.launch_cli_in_tab(self.cli, self.model, self._surf)

    def run(self, task_id: str, prompt: str, log_fp) -> str:
        if not self._surf: raise RuntimeError("cmux surface not ready")
        m = mm()
        with self._mm_lock:  # one prompt at a time per tab
            prompt_sent_at = time.time()
            mark = m.send_prompt_to_tab(self._surf, prompt)
            log_fp.write(f"[dock] prompt sent, mark={mark} ts={prompt_sent_at}\n"); log_fp.flush()
            sb = m.wait_idle(self._surf, log_fp, max_s=1800)
            # Prefer structured session log tailing (reliable across TUI redraws);
            # fall back to scrollback diff for CLIs that don't persist sessions.
            resp = self._extract_via_log_tail(prompt_sent_at, log_fp)
            src = "log-tail"
            if resp is None:
                resp = m.extract_response_diff(sb, mark, prompt)
                src = "scrollback-diff"
        log_fp.write(f"[dock] response len={len(resp)} via={src}\n"); log_fp.flush()
        return resp

    def _extract_via_log_tail(self, since_ts: float, log_fp):
        """Read the CLI's persistent session log to pull the newest assistant message
        after `since_ts`. Returns None if not supported or nothing fresh found.
        Retries briefly to give the CLI time to flush its jsonl."""
        slug = _slug_of(self.cli)
        for attempt in range(4):
            if self.cli.endswith("-code") or self.cli.startswith("cc-"):
                r = self._tail_cc_clone_jsonl(slug, since_ts)
            elif self.cli == "codex":
                r = self._tail_codex_jsonl(since_ts)
            elif self.cli == "gemini":
                r = self._tail_gemini_session(since_ts)
            else:
                return None  # claude / claude-team / unknown → scrollback fallback
            if r:
                log_fp.write(f"[dock] log-tail hit on attempt {attempt}\n"); log_fp.flush()
                return r
            time.sleep(0.5)
        return None

    def _tail_gemini_session(self, since_ts: float):
        """Read ~/.gemini/tmp/<project>/chats/session-*.json, find newest file
        modified after since_ts, return last 'gemini'-type message's text content."""
        gdir = Path.home() / ".gemini" / "tmp"
        if not gdir.exists(): return None
        cands = [f for f in gdir.rglob("session-*.json") if f.stat().st_mtime > since_ts - 5]
        if not cands: return None
        latest = max(cands, key=lambda f: f.stat().st_mtime)
        try:
            sess = json.loads(latest.read_text())
        except Exception: return None
        last_text = None
        for m in sess.get("messages", []):
            if m.get("type") != "gemini": continue
            c = m.get("content")
            if isinstance(c, str):
                last_text = c
            elif isinstance(c, list):
                # content might be [{text: ...}] or similar
                parts = []
                for p in c:
                    if isinstance(p, dict) and p.get("text"): parts.append(p["text"])
                    elif isinstance(p, str): parts.append(p)
                if parts: last_text = "\n".join(parts)
        return last_text

    def _tail_cc_clone_jsonl(self, slug: str, since_ts: float):
        proj_dir = Path.home() / ".claude-envs" / slug / ".claude" / "projects"
        if not proj_dir.exists(): return None
        candidates = [f for f in proj_dir.rglob("*.jsonl")
                      if f.stat().st_mtime > since_ts - 5]
        if not candidates: return None
        latest = max(candidates, key=lambda f: f.stat().st_mtime)
        last_text = None
        try:
            for line in latest.read_text().splitlines():
                try: d = json.loads(line)
                except Exception: continue
                if d.get("type") != "assistant": continue
                msg = d.get("message") or {}
                if msg.get("role") != "assistant": continue
                content = msg.get("content", [])
                if not isinstance(content, list): continue
                parts = [c.get("text","") for c in content
                         if isinstance(c, dict) and c.get("type") == "text"]
                if parts: last_text = "\n".join(parts)
        except Exception: return None
        return last_text

    def _tail_codex_jsonl(self, since_ts: float):
        from datetime import datetime as _dt
        today = _dt.now().strftime("%Y/%m/%d")
        sess_dir = Path.home() / ".codex" / "sessions" / today
        if not sess_dir.exists(): return None
        candidates = [f for f in sess_dir.glob("*.jsonl")
                      if f.stat().st_mtime > since_ts - 5]
        if not candidates: return None
        latest = max(candidates, key=lambda f: f.stat().st_mtime)
        last_msg = None
        try:
            for line in latest.read_text().splitlines():
                try: d = json.loads(line)
                except Exception: continue
                payload = d.get("payload") or {}
                if d.get("type") == "event_msg" and payload.get("type") == "task_complete":
                    lam = payload.get("last_agent_message", "")
                    if lam: last_msg = lam
        except Exception: return None
        return last_msg

    def cancel(self, task_id: str):
        """Interrupt the running prompt by sending Escape (Agents usually bind it to cancel)."""
        if not self._surf: return
        m = mm()
        m.cmux("send-key", "--surface", self._surf, "Escape")

    def shutdown(self):
        if self._surf:
            try: mm().cmux_close(self._surf)
            except Exception: pass
            self._surf = None
            sf = ROOT / self.team / f"{self.agent}.a2a.surface"
            if sf.exists(): sf.unlink()

def _rpc_tasks_get(team, params):
    tid = params.get("id") or params.get("taskId")
    t = _get_task(team, tid)
    if t is None: raise KeyError(f"task not found: {tid}")
    return t

def _rpc_tasks_cancel(team, params):
    tid = params.get("id") or params.get("taskId")
    t = _get_task(team, tid)
    if t is None: raise KeyError(f"task not found: {tid}")
    # Flip state to canceled + persist BEFORE signaling so any concurrent
    # message/send sees the authoritative terminal state via either CANCELED set
    # or a fresh tasks.json read.
    CANCELED.add(tid)
    t["status"] = {"state": "canceled", "timestamp": mm().now()}
    _upsert_task(team, t)
    if BACKEND is not None:
        try: BACKEND.cancel(tid)
        except Exception as e:
            sys.stderr.write(f"[cancel] backend error: {e}\n")
    return t

# ────── HTTP handler ──────
class A2AHandler(BaseHTTPRequestHandler):
    server_version = "mmteam-a2a/1.0"
    # Injected by Server factory
    AGENT_CARD: dict
    TEAM: str; AGENT: str; CLI: str; MODEL: str; TOKEN: str

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{mm().now()}] {self.address_string()} {fmt % args}\n")

    def _reply(self, code: int, body: dict|str, ctype="application/json"):
        data = body if isinstance(body, (bytes, bytearray)) else (
            json.dumps(body, ensure_ascii=False).encode() if isinstance(body, dict) else str(body).encode())
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth_ok(self) -> bool:
        h = self.headers.get("Authorization", "")
        return h == f"Bearer {self.TOKEN}"

    def do_GET(self):
        if self.path.rstrip("/") in ("/.well-known/agent-card.json", "/.well-known/agent.json"):
            return self._reply(200, self.AGENT_CARD)
        if self.path == "/health":
            return self._reply(200, {"status": "ok", "team": self.TEAM, "agent": self.AGENT})
        self._reply(404, {"error": "not found"})

    def do_POST(self):
        if not self._auth_ok():
            return self._reply(401, {"jsonrpc":"2.0","error":{"code":-32001,"message":"unauthorized"}, "id": None})
        n = int(self.headers.get("Content-Length","0") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try: req = json.loads(raw)
        except Exception as e:
            return self._reply(400, {"jsonrpc":"2.0","error":{"code":-32700,"message":f"parse error: {e}"},"id":None})
        rid = req.get("id")
        method = req.get("method","")
        params = req.get("params") or {}
        try:
            if method == "message/send":
                result = _rpc_message_send(self.TEAM, self.AGENT, self.CLI, self.MODEL, params)
            elif method == "tasks/get":
                result = _rpc_tasks_get(self.TEAM, params)
            elif method == "tasks/cancel":
                result = _rpc_tasks_cancel(self.TEAM, params)
            else:
                return self._reply(200, {"jsonrpc":"2.0","error":{"code":-32601,"message":f"method not found: {method}"},"id":rid})
            self._reply(200, {"jsonrpc":"2.0","result":result,"id":rid})
        except KeyError as e:
            self._reply(200, {"jsonrpc":"2.0","error":{"code":-32002,"message":f"task not found: {e}"},"id":rid})
        except ValueError as e:
            self._reply(200, {"jsonrpc":"2.0","error":{"code":-32602,"message":str(e)},"id":rid})
        except Exception as e:
            self._reply(200, {"jsonrpc":"2.0","error":{"code":-32603,"message":f"internal: {e}"},"id":rid})

# ────── Registry + PID tracking ──────
def _registry_path(team): return ROOT / team / "a2a-registry.json"
def _pid_path(team, agent): return ROOT / team / f"{agent}.a2a.pid"

def _write_registry_entry(team, agent, url, token):
    reg = mm().load_json(_registry_path(team), {})
    reg[agent] = {"url": url, "bearer_token": token, "kind": "local"}
    mm().save_json(_registry_path(team), reg)

def _remove_registry_entry(team, agent):
    reg = mm().load_json(_registry_path(team), {})
    if agent in reg and reg[agent].get("kind") == "local":
        del reg[agent]
        mm().save_json(_registry_path(team), reg)

# ────── main ──────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--team", required=True)
    ap.add_argument("--agent", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = auto-assign free port")
    ap.add_argument("--print-card", action="store_true", help="Print Agent Card JSON and exit (no server)")
    ap.add_argument("--dock", action="store_true", help="Use CmuxDockBackend: persistent visible cmux tab per teammate")
    args = ap.parse_args()

    cfg_path = ROOT / args.team / "config.json"
    if not cfg_path.exists(): sys.exit(f"team config missing: {cfg_path}")
    cfg = json.loads(cfg_path.read_text())
    member = next((m for m in cfg.get("members", []) if m.get("id") == args.agent), None)
    if not member: sys.exit(f"agent {args.agent} not in team {args.team}")
    cli = member["cli"]; model = member.get("model", "")

    # Token: team-level, generated once on first A2A spawn
    token = cfg.get("a2a_token")
    if not token:
        token = uuid.uuid4().hex
        cfg["a2a_token"] = token
        cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))
        os.chmod(cfg_path, 0o600)

    # Bind socket first to learn the actual port, then hand to ThreadingHTTPServer
    httpd = ThreadingHTTPServer((args.host, args.port), A2AHandler)
    actual_port = httpd.server_address[1]
    url = f"http://{args.host}:{actual_port}/"
    card = agent_card_for(args.agent, cli, model, url, args.team)

    if args.print_card:
        print(json.dumps(card, ensure_ascii=False, indent=2))
        httpd.server_close()
        return

    # Inject per-instance config onto the handler class
    A2AHandler.AGENT_CARD = card
    A2AHandler.TEAM = args.team
    A2AHandler.AGENT = args.agent
    A2AHandler.CLI = cli
    A2AHandler.MODEL = model
    A2AHandler.TOKEN = token

    # Register + persist card
    card_dir = ROOT / args.team / "agent-cards"; card_dir.mkdir(parents=True, exist_ok=True)
    (card_dir / f"{args.agent}.json").write_text(json.dumps(card, ensure_ascii=False, indent=2))
    _write_registry_entry(args.team, args.agent, url, token)
    _pid_path(args.team, args.agent).write_text(str(os.getpid()))

    # Select backend + wire startup
    log_path = _log_dir(args.team) / f"{args.agent}.a2a.log"
    log_fp = open(log_path, "a", buffering=1)
    global BACKEND
    if args.dock:
        BACKEND = CmuxDockBackend(args.agent, cli, model, args.team, log_fp)
    else:
        BACKEND = HeadlessBackend(args.agent, cli, model, args.team, log_fp)
    try:
        BACKEND.startup()
    except Exception as e:
        sys.stderr.write(f"[FATAL] backend startup failed: {e}\n"); httpd.server_close(); sys.exit(1)

    def _cleanup():
        try: BACKEND.shutdown()
        except Exception: pass
        _remove_registry_entry(args.team, args.agent)
        try: _pid_path(args.team, args.agent).unlink()
        except FileNotFoundError: pass
    atexit.register(_cleanup)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: (_cleanup(), sys.exit(0)))

    sys.stderr.write(f"[{mm().now()}] a2a-server up: team={args.team} agent={args.agent} cli={cli} backend={BACKEND.__class__.__name__} {url}\n")
    try: httpd.serve_forever()
    except KeyboardInterrupt: pass
    finally: httpd.server_close()

if __name__ == "__main__":
    main()
