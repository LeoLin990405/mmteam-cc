#!/usr/bin/env python3
"""
mmteam-mcp — stdio MCP server exposing mmteam a2a HTTP mode to Claude Code.

Claude Code registers this in ~/.claude.json under mcpServers. Once enabled,
Claude sees tools like `mcp__mmteam__a2a_send` and can dispatch work to any
teammate (kimi/codex/gemini/etc.) that's been spawned via `mmteam a2a spawn`.

Why MCP + A2A: A2A defines agent↔agent HTTP protocol; MCP defines tool↔agent
protocol. This server is the bridge so Claude (via MCP) can call A2A agents.

Protocol: stdio JSON-RPC 2.0, newline-delimited, per https://spec.modelcontextprotocol.io
"""
import json, os, sys, subprocess, urllib.request, urllib.error, uuid, time
from pathlib import Path

ROOT = Path.home() / ".claude" / "teams"
MMTEAM = str(Path.home() / "bin" / "mmteam")

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "mmteam", "version": "1.0.0"}

# ────── helpers ──────
def _read_json(p, default):
    try: return json.loads(Path(p).read_text())
    except Exception: return default

def _registry(team): return _read_json(ROOT / team / "a2a-registry.json", {})

def _resolve(team, agent):
    reg = _registry(team)
    if agent not in reg: raise ValueError(f"agent {agent} not in registry for team {team}. Run a2a_spawn first or register_remote.")
    e = reg[agent]
    return e["url"], e["bearer_token"]

def _rpc(url, token, method, params, timeout=1800):
    req = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc":"2.0","id":uuid.uuid4().hex,"method":method,"params":params}).encode(),
        headers={"Content-Type":"application/json","Authorization":f"Bearer {token}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode(errors="replace"))

def _sh(args, input_bytes=None):
    r = subprocess.run(args, capture_output=True, text=True, input=input_bytes)
    return r.returncode, r.stdout, r.stderr

# ────── tool implementations ──────
def tool_list_teams(_):
    if not ROOT.exists(): return "(no teams)"
    names = sorted(p.name for p in ROOT.iterdir() if p.is_dir() and (p/"config.json").exists())
    if not names: return "(no teams)"
    lines = []
    for n in names:
        cfg = _read_json(ROOT/n/"config.json", {})
        reg = _registry(n)
        members = cfg.get("members", []) if isinstance(cfg, dict) else []
        mstr = ", ".join(f"{m.get('id','?')}({m.get('cli','?')})" for m in members)
        lines.append(f"  {n}: {len(members)} members [{mstr}]. a2a-registry={len(reg)} entries")
    return "\n".join(lines)

def tool_a2a_spawn(args):
    team = args["team"]; dock = bool(args.get("dock")); monitor = bool(args.get("monitor"))
    cmd = [MMTEAM, "a2a", "spawn", team]
    if dock: cmd.append("--dock")
    if monitor: cmd.append("--monitor")
    rc, out, err = _sh(cmd)
    return out + (("\n[stderr]\n"+err) if rc else "")

def tool_a2a_stop(args):
    rc, out, err = _sh([MMTEAM, "a2a", "stop", args["team"]])
    return out + (("\n[stderr]\n"+err) if rc else "")

def tool_a2a_ls(args):
    team = args["team"]; reg = _registry(team)
    if not reg: return f"(registry empty — run a2a_spawn first)"
    lines = []
    for mid, e in reg.items():
        pf = ROOT / team / f"{mid}.a2a.pid"
        alive = ""
        if e.get("kind") == "local":
            try: alive = " [alive]" if pf.exists() and _proc_alive(int(pf.read_text())) else " [dead]"
            except Exception: alive = " [?]"
        lines.append(f"  {mid:12s} {e['kind']:6s} {e['url']}{alive}")
    return "\n".join(lines)

def _proc_alive(pid):
    try: os.kill(pid, 0); return True
    except Exception: return False

def tool_a2a_card(args):
    url, _ = _resolve(args["team"], args["agent"])
    req = urllib.request.Request(url.rstrip("/")+"/.well-known/agent-card.json")
    with urllib.request.urlopen(req, timeout=10) as r:
        card = json.loads(r.read())
    return json.dumps(card, ensure_ascii=False, indent=2)

def tool_a2a_send(args):
    url, tok = _resolve(args["team"], args["agent"])
    msg = {"role":"user","messageId":str(uuid.uuid4()),
           "parts":[{"kind":"text","text":args["text"]}]}
    if args.get("session"):
        msg["contextId"] = args["session"]
    params = {"message": msg}
    resp = _rpc(url, tok, "message/send", params)
    if "error" in resp:
        return f"ERROR: {json.dumps(resp['error'], ensure_ascii=False)}"
    r = resp["result"]
    text = ""
    arts = r.get("artifacts") or []
    if arts and arts[0].get("parts"):
        for p in arts[0]["parts"]:
            if p.get("kind") == "text": text = p.get("text",""); break
    return (f"task_id: {r.get('id')}\nstatus: {r.get('status',{}).get('state')}\n"
            f"artifact_count: {len(arts)}\n\n--- output ---\n{text}")

_ASK_SKILL_KEYWORDS = {
    "chinese-coding":   ["中文", "中国", "汉字", "简体", "繁体", "chinese"],
    "long-context":     ["long", "long-context", "big file", "大文件", "summarize", "summary", "1m", "500k", "100k", "分析", "analyze"],
    "algorithm-design": ["algorithm", "algo", "complexity", "optimal", "leetcode", "lc ", "big o", "dp ", "graph", "tree"],
    "code-execution":   ["code", "program", "script", "python", "javascript", "typescript", "rust", " go ", "java ", "write", "implement", "function", "class"],
    "doc-summary":      ["summarize", "summary", "tldr", "brief", "总结", "概括", "提炼"],
    "multi-file-review":["review", "audit", "cross-file", "project", "repo", "全局", "审查", "代码审"],
    "reasoning-effort": ["reason", "stepwise", "推导"],
    "english-coding":   ["english"],
    # v2.9: differentiated CC-clone routing keywords
    "sql-engineering":  ["sql", "select ", "doris", "adb", "polardb", "mysql", "oracle", "查询", "数据库", "join ", "group by", "where"],
    "fast-inference":   ["fast", "quick", "速度", "急", "立刻", "urgent", "asap", "immediately"],
    "math-logic":       ["math", "数学", "prove", "proof", "证明", "逻辑", "equation", "theorem", "定理", "质数", "素数"],
    "experimental-model":["实验", "新模型", "测试模型", "trial", "experimental", "explore"],
    "parallel-sidecars":["parallel", "并行", "fan out", "fanout", "subteam", "sidecar", "team-create", "分身并行", "多角度"],
}

def _send_blocking(team, agent, text):
    url, tok = _resolve(team, agent)
    resp = _rpc(url, tok, "message/send",
        {"message":{"role":"user","messageId":str(uuid.uuid4()),
                    "parts":[{"kind":"text","text":text}]}})
    if "error" in resp: raise RuntimeError(f"{agent}: {resp['error']}")
    r = resp.get("result") or {}; out = ""
    arts = r.get("artifacts") or []
    if arts and arts[0].get("parts"):
        for p in arts[0]["parts"]:
            if p.get("kind") == "text": out = p.get("text",""); break
    return {"task_id": r.get("id"), "state": (r.get("status") or {}).get("state","?"), "text": out}

def tool_a2a_pipeline(args):
    team = args["team"]; text = args["text"]
    reg = _registry(team)
    if not reg: return f"(no registered teammates)"
    for role in ("writer","reviewer","synth"):
        if args.get(role) not in reg:
            return f"ERROR: {role}='{args.get(role)}' not in registry. Available: {list(reg.keys())}"

    steps = []
    try:
        w = _send_blocking(team, args["writer"], text)
        steps.append({"role":"writer","agent":args["writer"], **w})
        if w["state"] != "completed":
            return json.dumps({"original":text, "steps":steps, "aborted_at":"writer"}, ensure_ascii=False, indent=2)

        r_prompt = (f"请审查下面由 {args['writer']} 给出的回答。指出：正确性问题、改进点、遗漏。简洁不啰嗦。\n\n"
                    f"原问题：{text}\n\n{args['writer']} 的回答：\n{w['text']}")
        rv = _send_blocking(team, args["reviewer"], r_prompt)
        steps.append({"role":"reviewer","agent":args["reviewer"], **rv})
        if rv["state"] != "completed":
            return json.dumps({"original":text, "steps":steps, "aborted_at":"reviewer"}, ensure_ascii=False, indent=2)

        s_prompt = (f"请整合下面材料，给出最终答案。融合 writer 内容和 reviewer 改进意见，去啰嗦留关键。\n\n"
                    f"原问题：{text}\n\n[writer={args['writer']}]\n{w['text']}\n\n[reviewer={args['reviewer']}]\n{rv['text']}")
        sy = _send_blocking(team, args["synth"], s_prompt)
        steps.append({"role":"synth","agent":args["synth"], **sy})
    except Exception as e:
        return json.dumps({"original":text, "steps":steps, "error":str(e)}, ensure_ascii=False, indent=2)
    return json.dumps({"original":text, "steps":steps}, ensure_ascii=False, indent=2)

def tool_a2a_watch(args):
    rc, out, err = _sh([MMTEAM, "a2a", "watch", args["team"]])
    return out + (("\n[stderr]\n"+err) if rc else "")

def tool_a2a_unwatch(args):
    rc, out, err = _sh([MMTEAM, "a2a", "unwatch", args["team"]])
    return out + (("\n[stderr]\n"+err) if rc else "")

def tool_a2a_routes(args):
    """Dry-run router — forward to CLI (which already has quota-aware scoring)."""
    rc, out, err = _sh([MMTEAM, "a2a", "routes", args["team"], args["text"], "--json"])
    return out if out else (err or "(empty)")

def tool_a2a_who(args):
    rc, out, err = _sh([MMTEAM, "a2a", "who", args["team"]])
    return out if out else (err or "(empty)")

def tool_a2a_quota(args):
    """Rolling-window request count per teammate (for subscription plan users)."""
    from datetime import datetime as _dt, timedelta
    team = args["team"]
    ledger = ROOT / team / "cost-ledger.jsonl"
    if not ledger.exists():
        return f"(no ledger for {team})"
    rows = []
    for line in ledger.read_text().splitlines():
        try: rows.append(json.loads(line))
        except Exception: continue
    now = _dt.now()
    windows = {"5min": timedelta(minutes=5), "1h": timedelta(hours=1), "5h": timedelta(hours=5), "24h": timedelta(hours=24)}
    per_agent = {}
    for r in rows:
        try: ts = _dt.fromisoformat(r.get("ts","").split("+")[0])
        except Exception: continue
        age = now - ts
        aid = r.get("agent","?")
        b = per_agent.setdefault(aid, {w: 0 for w in windows})
        b.setdefault("tokens_24h", 0)
        for w, dt in windows.items():
            if age <= dt: b[w] += 1
        if age <= windows["24h"]:
            b["tokens_24h"] += (r.get("usage") or {}).get("total", 0)
    return json.dumps({"team": team, "now": now.isoformat(timespec='seconds'),
                       "per_agent": per_agent,
                       "hint": "Kimi Allegretto 300-1200 reqs/5h · watch 5h column for subscription caps"},
                      ensure_ascii=False, indent=2)

def tool_a2a_cost_report(args):
    """Aggregate cost-ledger.jsonl for a team; supports since/by/json."""
    team = args["team"]
    ledger = ROOT / team / "cost-ledger.jsonl"
    if not ledger.exists():
        return f"(no cost-ledger for {team} — no completed tasks yet)"
    rows = []
    for line in ledger.read_text().splitlines():
        try: rows.append(json.loads(line))
        except Exception: continue
    since = args.get("since","")
    if since: rows = [r for r in rows if r.get("ts","") >= since]
    by = args.get("by","")
    grouped = {}
    for r in rows:
        if by == "agent": key = r.get("agent","?")
        elif by == "day": key = (r.get("ts","") or "")[:10]
        elif by == "cli": key = r.get("cli","?")
        else: key = "total"
        g = grouped.setdefault(key, {"n":0,"input":0,"output":0,"total_tok":0,"cost_usd":0.0,"elapsed_s":0.0})
        g["n"] += 1
        u = r.get("usage") or {}
        g["input"] += u.get("input",0)
        g["output"] += u.get("output",0)
        g["total_tok"] += u.get("total",0)
        g["cost_usd"] += r.get("cost_usd",0) or 0
        g["elapsed_s"] += r.get("elapsed_s",0) or 0
    return json.dumps({"team":team,"since":since or None,"by":by or "total","groups":grouped}, ensure_ascii=False, indent=2)

def tool_a2a_ask(args):
    team = args["team"]; text = args["text"]
    reg = _registry(team)
    if not reg: return f"(no teammates registered for {team})"
    # Gather alive agents
    alive = []
    for mid, e in reg.items():
        if e.get("kind") == "local":
            pf = ROOT / team / f"{mid}.a2a.pid"
            if pf.exists():
                try:
                    if _proc_alive(int(pf.read_text())): alive.append(mid)
                except Exception: pass
        else: alive.append(mid)
    if not alive: return "(no alive teammates)"

    low = text.lower()
    scores = {mid: 0 for mid in alive}
    card_dir = ROOT / team / "agent-cards"
    for mid in alive:
        cp = card_dir / f"{mid}.json"
        if cp.exists():
            try:
                card = json.loads(cp.read_text())
                for s in card.get("skills", []):
                    sid = s.get("id", "")
                    for kw in _ASK_SKILL_KEYWORDS.get(sid, []):
                        if kw in low: scores[mid] += 1
            except Exception: pass
    best = max(scores.items(), key=lambda x: x[1])
    chosen = best[0] if best[1] > 0 else sorted(alive)[0]

    url, tok = _resolve(team, chosen)
    params = {"message": {"role":"user","messageId":str(uuid.uuid4()),
                          "parts":[{"kind":"text","text":text}]}}
    resp = _rpc(url, tok, "message/send", params)
    if "error" in resp: return f"ERROR: {resp['error']}"
    r = resp["result"]; arts = r.get("artifacts") or []; tx = ""
    if arts and arts[0].get("parts"):
        for p in arts[0]["parts"]:
            if p.get("kind") == "text": tx = p.get("text",""); break
    return json.dumps({"routed_to": chosen, "score": scores.get(chosen, 0),
                       "all_scores": scores, "task_id": r.get("id"),
                       "status": (r.get("status") or {}).get("state"), "text": tx},
                      ensure_ascii=False, indent=2)

def tool_a2a_fanout(args):
    """Parallel dispatch same prompt to N teammates; return structured comparison with fusion analysis."""
    import concurrent.futures as _cf
    import re as _re
    team = args["team"]; text = args["text"]
    reg = _registry(team)
    if not reg: return f"(no registered teammates in {team} — run a2a_spawn first)"
    if args.get("agents"):
        ids = [a.strip() for a in args["agents"] if a.strip()] if isinstance(args.get("agents"), list) else [a.strip() for a in str(args["agents"]).split(",") if a.strip()]
    else:
        ids = list(reg.keys())
    judge = args.get("judge", "") or ""
    if judge and not args.get("agents"):
        ids = [i for i in ids if i != judge]
    missing = [a for a in ids if a not in reg]
    if missing: return f"ERROR: unknown teammate(s): {missing}. Available: {list(reg.keys())}"
    if judge and judge not in reg:
        return f"ERROR: judge '{judge}' not registered. Available: {list(reg.keys())}"

    def _dispatch(aid):
        url, tok = _resolve(team, aid)
        params = {"message": {"role":"user","messageId":str(uuid.uuid4()),
                              "parts":[{"kind":"text","text":text}]}}
        return aid, _rpc(url, tok, "message/send", params)

    out = []
    with _cf.ThreadPoolExecutor(max_workers=min(len(ids), 10)) as exe:
        futs = {exe.submit(_dispatch, a): a for a in ids}
        rmap = {}
        for f in _cf.as_completed(futs):
            aid, resp = f.result(); rmap[aid] = resp
    for aid in ids:
        r = rmap.get(aid, {})
        if "error" in r:
            out.append({"agent": aid, "state": "error", "error": r.get("error")}); continue
        res = r.get("result") or {}
        tx = ""
        arts = res.get("artifacts") or []
        if arts and arts[0].get("parts"):
            for p in arts[0]["parts"]:
                if p.get("kind") == "text": tx = p.get("text",""); break
        out.append({
            "agent": aid,
            "state": (res.get("status") or {}).get("state","?"),
            "task_id": res.get("id",""),
            "text": tx,
        })

    # Fusion analysis: Jaccard similarity + outlier detection
    # Tokens = ASCII words + CJK char-bigrams (handles Chinese without word spaces)
    def _tokens(s):
        t = set(_re.findall(r'[a-zA-Z][a-zA-Z0-9_]*', s.lower()))
        for run in _re.findall(r'[\u4e00-\u9fff]+', s):
            t.update(run[i:i+2] for i in range(len(run)-1))
            t.update(run)
        return t
    done = [(s["agent"], s["text"]) for s in out if s.get("state") == "completed" and s.get("text")]
    analysis = {"pairs": [], "consensus_score": 0.0, "consensus_label": "n/a", "outlier": None}
    if len(done) >= 2:
        toks = {a: _tokens(t) for a, t in done}
        pairs = []; avg = {a: 0.0 for a, _ in done}; cnt = {a: 0 for a, _ in done}
        for i, (a, _) in enumerate(done):
            for j in range(i+1, len(done)):
                b = done[j][0]
                u = toks[a] | toks[b]
                sim = (len(toks[a] & toks[b]) / len(u)) if u else 0.0
                pairs.append([a, b, round(sim, 3)])
                avg[a] += sim; cnt[a] += 1; avg[b] += sim; cnt[b] += 1
        for k in avg: avg[k] = avg[k] / cnt[k] if cnt[k] else 0.0
        consensus = sum(p[2] for p in pairs) / len(pairs)
        label = "high-consensus" if consensus >= 0.5 else ("moderate-consensus" if consensus >= 0.25 else "low-consensus")
        outlier = None; outlier_avg = 0.0
        if len(avg) >= 3:
            sorted_avg = sorted(avg.items(), key=lambda x: x[1])
            if sorted_avg[1][1] - sorted_avg[0][1] > 0.15:
                outlier = sorted_avg[0][0]; outlier_avg = round(sorted_avg[0][1], 3)
        analysis = {"pairs": pairs, "consensus_score": round(consensus, 3),
                    "consensus_label": label, "outlier": outlier, "outlier_avg": outlier_avg,
                    "avg_similarity": {k: round(v, 3) for k, v in avg.items()}}

    # Claude-as-judge synthesis (semantic consensus beyond Jaccard)
    if judge and len(done) >= 2 and judge not in [d[0] for d in done]:
        answers_block = "\n\n".join(f"[{a}]\n{t.strip()}" for a, t in done)
        judge_prompt = (
            f"以下是 {len(done)} 个不同模型对同一问题的回答。请做 3 件事（用中文，简短）：\n"
            f"1. 是否存在明显错误或分歧？指出哪个模型跑偏了（如有）\n"
            f"2. 给一个融合多家优点的共识版本\n"
            f"3. 一句话总评每家风格\n\n"
            f"问题：{text}\n\n"
            f"回答：\n{answers_block}"
        )
        jurl, jtok = _resolve(team, judge)
        jresp = _rpc(jurl, jtok, "message/send",
            {"message":{"role":"user","messageId":str(uuid.uuid4()),
                        "parts":[{"kind":"text","text":judge_prompt}]}})
        jres = jresp.get("result") or {}
        jtext = ""
        jarts = jres.get("artifacts") or []
        if jarts and jarts[0].get("parts"):
            for p in jarts[0]["parts"]:
                if p.get("kind") == "text": jtext = p.get("text",""); break
        analysis["judge"] = {"agent": judge, "task_id": jres.get("id",""),
                             "state": (jres.get("status") or {}).get("state","?"),
                             "text": jtext}
    return json.dumps({"results": out, "analysis": analysis}, ensure_ascii=False, indent=2)

def tool_a2a_get(args):
    url, tok = _resolve(args["team"], args["agent"])
    resp = _rpc(url, tok, "tasks/get", {"id": args["task_id"]}, timeout=10)
    return json.dumps(resp.get("result", resp), ensure_ascii=False, indent=2)

def tool_a2a_cancel(args):
    url, tok = _resolve(args["team"], args["agent"])
    resp = _rpc(url, tok, "tasks/cancel", {"id": args["task_id"]}, timeout=30)
    return json.dumps(resp.get("result", resp), ensure_ascii=False, indent=2)

def tool_a2a_register_remote(args):
    team = args["team"]; reg = _registry(team)
    reg[args["agent"]] = {"url": args["url"].rstrip("/")+"/", "bearer_token": args["token"], "kind": "remote"}
    (ROOT/team/"a2a-registry.json").write_text(json.dumps(reg, indent=2, ensure_ascii=False))
    return f"registered {args['agent']} → {args['url']}"

def tool_a2a_discover(args):
    url = args["url"].rstrip("/") + "/.well-known/agent-card.json"
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.dumps(json.loads(r.read()), ensure_ascii=False, indent=2)

# ────── tool registry (name → (handler, inputSchema, description)) ──────
TOOLS = {
    "a2a_list_teams": (tool_list_teams,
        {"type":"object","properties":{},"additionalProperties":False},
        "List all mmteam teams on this machine with member counts and current a2a registry size."),
    "a2a_spawn": (tool_a2a_spawn,
        {"type":"object","properties":{
            "team":{"type":"string","description":"Team name"},
            "dock":{"type":"boolean","description":"Multi-pane cmux grid: each teammate gets its own visible pane (up to 6)","default":False},
            "monitor":{"type":"boolean","description":"Add top-strip monitor pane showing A2A task event stream (requires dock)","default":False}},
         "required":["team"]},
        "Start A2A HTTP daemons for every teammate in a team. Each teammate gets its own auto-port server exposing Agent Card + JSON-RPC. With dock=true, each teammate runs in its own cmux pane (grid layout) and sessions persist across tasks. With monitor=true, also opens a top-strip monitor pane showing the live task event stream."),
    "a2a_stop": (tool_a2a_stop,
        {"type":"object","properties":{"team":{"type":"string"}},"required":["team"]},
        "SIGTERM all a2a daemons for the team and clean the local-kind registry entries."),
    "a2a_ls": (tool_a2a_ls,
        {"type":"object","properties":{"team":{"type":"string"}},"required":["team"]},
        "Show the A2A registry for a team: each teammate's URL, kind (local|remote), and liveness."),
    "a2a_card": (tool_a2a_card,
        {"type":"object","properties":{"team":{"type":"string"},"agent":{"type":"string"}},"required":["team","agent"]},
        "Fetch a teammate's Agent Card (A2A v0.3 discovery document: skills, capabilities, auth schemes)."),
    "a2a_send": (tool_a2a_send,
        {"type":"object","properties":{
            "team":{"type":"string"},
            "agent":{"type":"string","description":"Teammate id within the team"},
            "text":{"type":"string","description":"The prompt to dispatch"},
            "session":{"type":"string","description":"contextId for multi-turn chain. Reuse same id across calls to maintain conversation history. Server prepends prior turns to each prompt automatically (capped at 20 turns)."}},
         "required":["team","agent","text"]},
        "Dispatch a prompt to a teammate via JSON-RPC `message/send`. BLOCKS until the CLI returns. With `session`, maintains conversation history across calls — reuse same session id for multi-turn. Returns task_id + status + artifact text."),
    "a2a_pipeline": (tool_a2a_pipeline,
        {"type":"object","properties":{
            "team":{"type":"string"},
            "text":{"type":"string","description":"Original prompt for the writer"},
            "writer":{"type":"string","description":"Teammate id that produces initial answer"},
            "reviewer":{"type":"string","description":"Teammate id that critiques writer's output"},
            "synth":{"type":"string","description":"Teammate id that synthesizes final answer from writer+reviewer"}},
         "required":["team","text","writer","reviewer","synth"]},
        "Sequential 3-stage workflow: writer produces answer → reviewer critiques it → synth consolidates both into final. Each stage blocks on previous. Returns {original, steps:[{role,agent,state,text,task_id}×3]}. Use for quality-focused tasks where multi-model review value > latency cost."),
    "a2a_cost_report": (tool_a2a_cost_report,
        {"type":"object","properties":{
            "team":{"type":"string"},
            "since":{"type":"string","description":"ISO date/time prefix filter, e.g. '2026-04-16' or '2026-04-16T15'"},
            "by":{"type":"string","enum":["agent","day","cli"],"description":"Grouping dimension (default: total)"}},
         "required":["team"]},
        "Aggregate the team's persistent cost ledger (jsonl appended on each completed task). Returns JSON with per-group tasks/input/output/total_tokens/elapsed_s/cost_usd. Use to answer 'how much has team X cost me this week?' or 'which teammate burns most tokens?'."),
    "a2a_quota": (tool_a2a_quota,
        {"type":"object","properties":{"team":{"type":"string"}},"required":["team"]},
        "Rolling-window request count per teammate: 5min / 1h / 5h / 24h windows + tokens in last 24h. For subscription-plan users (Kimi Allegretto, GLM Plan, MiniMax Token Plan, etc.) — watch the 5h column vs plan cap to avoid hitting limits."),
    "a2a_watch": (tool_a2a_watch,
        {"type":"object","properties":{"team":{"type":"string"}},"required":["team"]},
        "Open a multi-pane cmux observation workspace: top event-stream monitor strip + N panes each tailing a teammate's daemon log. Works regardless of headless/dock backend mode. Independent from `spawn --dock` (separate workspace names, can coexist). User must switch to cmux workspace '<team>-watch' to see it."),
    "a2a_unwatch": (tool_a2a_unwatch,
        {"type":"object","properties":{"team":{"type":"string"}},"required":["team"]},
        "Close the watch observation workspace for a team (reverses a2a_watch)."),
    "a2a_routes": (tool_a2a_routes,
        {"type":"object","properties":{"team":{"type":"string"},"text":{"type":"string"}},"required":["team","text"]},
        "DRY-RUN smart router: returns which teammate would be picked for this prompt + all scores + quota state, WITHOUT sending anything. Zero quota cost. Use to preview routing before committing a request."),
    "a2a_who": (tool_a2a_who,
        {"type":"object","properties":{"team":{"type":"string"}},"required":["team"]},
        "One-line team status per teammate: alive indicator + 5h request count / plan cap + last activity timestamp. Morning health-check summary."),
    "a2a_ask": (tool_a2a_ask,
        {"type":"object","properties":{
            "team":{"type":"string"},
            "text":{"type":"string","description":"The prompt. mmteam will pick the best-matching teammate by skill keywords."}},
         "required":["team","text"]},
        "Smart router: scans each alive teammate's Agent Card for skill keywords matching the prompt, picks the best-fit one, and dispatches message/send. Falls back to alphabetical first if no clear match. Returns {routed_to, all_scores, text}."),
    "a2a_fanout": (tool_a2a_fanout,
        {"type":"object","properties":{
            "team":{"type":"string"},
            "text":{"type":"string","description":"The prompt to broadcast"},
            "agents":{"type":"array","items":{"type":"string"},"description":"Subset of teammate ids (default: all in registry)"},
            "judge":{"type":"string","description":"Teammate id to act as synthesis judge after fanout (semantic consensus, beyond Jaccard). Auto-excluded from fanout if agents not specified."}},
         "required":["team","text"]},
        "Parallel-dispatch same prompt to N teammates; returns {results, analysis}. analysis has Jaccard similarity pairs + consensus_score + outlier detection. With `judge`, adds analysis.judge.text = that teammate's semantic synthesis (errors/consensus/style verdict). Use for cross-model validation (Jaccard catches divergence cheaply; judge adds semantic understanding)."),
    "a2a_get": (tool_a2a_get,
        {"type":"object","properties":{
            "team":{"type":"string"},"agent":{"type":"string"},"task_id":{"type":"string"}},
         "required":["team","agent","task_id"]},
        "Poll a task's current state + artifacts via JSON-RPC `tasks/get`. Useful after cancel or to re-fetch output."),
    "a2a_cancel": (tool_a2a_cancel,
        {"type":"object","properties":{
            "team":{"type":"string"},"agent":{"type":"string"},"task_id":{"type":"string"}},
         "required":["team","agent","task_id"]},
        "Cancel a running task via JSON-RPC `tasks/cancel`. Headless backend sends SIGTERM; dock backend sends Escape to the cmux tab."),
    "a2a_register_remote": (tool_a2a_register_remote,
        {"type":"object","properties":{
            "team":{"type":"string"},"agent":{"type":"string"},
            "url":{"type":"string"},"token":{"type":"string"}},
         "required":["team","agent","url","token"]},
        "Add a remote A2A teammate to the team registry (no local daemon spawned). Useful for Mac mini ↔ Mac Studio cross-machine teammates."),
    "a2a_discover": (tool_a2a_discover,
        {"type":"object","properties":{"url":{"type":"string"}},"required":["url"]},
        "Fetch `<url>/.well-known/agent-card.json` from any A2A-compliant endpoint. Use before register_remote to verify compatibility."),
}

# ────── MCP stdio loop ──────
def _send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()

def _log(msg):
    sys.stderr.write(f"[mmteam-mcp] {msg}\n"); sys.stderr.flush()

def _handle_initialize(req):
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {"tools": {}},
        "serverInfo": SERVER_INFO,
    }

def _handle_tools_list(req):
    return {"tools": [
        {"name": n, "description": desc, "inputSchema": schema}
        for n, (_fn, schema, desc) in TOOLS.items()
    ]}

def _handle_tools_call(req):
    params = req.get("params") or {}
    name = params.get("name")
    args = params.get("arguments") or {}
    if name not in TOOLS:
        return {"content": [{"type":"text","text":f"unknown tool: {name}"}], "isError": True}
    fn, _schema, _desc = TOOLS[name]
    try:
        text = fn(args)
    except Exception as e:
        return {"content": [{"type":"text","text":f"tool error: {e}"}], "isError": True}
    return {"content": [{"type":"text","text": text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)}]}

METHODS = {
    "initialize": _handle_initialize,
    "tools/list": _handle_tools_list,
    "tools/call": _handle_tools_call,
}

def main():
    _log(f"started (pid={os.getpid()}) — {len(TOOLS)} tools")
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try: req = json.loads(line)
        except Exception as e:
            _log(f"parse error: {e}"); continue
        mid = req.get("id")
        method = req.get("method", "")
        # Notifications have no id and expect no response
        if method == "notifications/initialized":
            _log("client ready"); continue
        if method.startswith("notifications/"):
            continue
        handler = METHODS.get(method)
        if handler is None:
            _send({"jsonrpc":"2.0","id":mid,
                   "error":{"code":-32601,"message":f"method not found: {method}"}})
            continue
        try:
            result = handler(req)
            _send({"jsonrpc":"2.0","id":mid,"result":result})
        except Exception as e:
            _log(f"handler error: {e}")
            _send({"jsonrpc":"2.0","id":mid,
                   "error":{"code":-32603,"message":f"internal: {e}"}})

if __name__ == "__main__":
    main()
