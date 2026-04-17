#!/usr/bin/env python3
"""
mmteam-a2a-monitor — chat-style live event stream for an mmteam A2A team.

Meant to run inside a cmux pane (top strip) alongside the teammate grid.
Polls tasks.json for state transitions and formats them as:

    [15:45:00] user   → gem     submit      "write fizzbuzz"            task=8a96...
    [15:45:02] gem    ↻ working
    [15:45:05] gem    ✓ completed     150 chars  → results/...md
    [15:45:06] user   → kimi    submit      "review: def fizz..."       task=f620...
    [15:45:12] kimi   ✓ completed      80 chars
    [15:45:15] kimi   ✗ canceled                                         task=2575...

Usage: mmteam-a2a-monitor.py <team-name> [--poll-ms 800] [--expand-artifacts]

Keyboard shortcuts when running on a tty:
  q - quit
  s - toggle artifact preview on/off (show first 200 chars of completed output)
  c - clear screen
"""
import argparse, json, os, sys, time, select, termios, tty, threading
from pathlib import Path
from datetime import datetime

ROOT = Path.home() / ".claude" / "teams"

# ANSI colors
CLR = {
    "reset": "\x1b[0m",
    "bold":  "\x1b[1m",
    "dim":   "\x1b[2m",
    "red":   "\x1b[31m",
    "green": "\x1b[32m",
    "yellow":"\x1b[33m",
    "blue":  "\x1b[34m",
    "cyan":  "\x1b[36m",
    "white": "\x1b[37m",
    "grey":  "\x1b[90m",
}
ICONS = {
    "submit":    ("→", "green"),
    "working":   ("↻", "yellow"),
    "completed": ("✓", "blue"),
    "failed":    ("✗", "red"),
    "canceled":  ("✗", "red"),
    "rejected":  ("✗", "red"),
    "input-required": ("?", "cyan"),
}

def hms(ts_iso: str) -> str:
    try: return ts_iso[11:19]
    except Exception: return "--:--:--"

def c(txt, color): return f"{CLR[color]}{txt}{CLR['reset']}"

def emit(ev: dict, expand_artifacts: bool):
    """Render a single event to stdout in chat style."""
    agent = ev.get("agent", "?")
    state = ev.get("state", "?")
    tid = ev.get("task_id", "")
    t_short = tid[:8] if tid else "--------"
    ts = hms(ev.get("ts", ""))
    icon, color = ICONS.get(state, ("•", "white"))
    prompt = ev.get("prompt_preview", "")
    extra = ev.get("extra", "")

    if state == "submit":
        line = (f"{c('[' + ts + ']', 'grey')} "
                f"{c('user', 'cyan')}  → {c(agent.ljust(8), 'bold')} "
                f"{c('submit', color)}  "
                f"{c(repr(prompt)[1:-1][:60] if prompt else '', 'white')}  "
                f"{c('task=' + t_short, 'dim')}")
    elif state == "working":
        line = (f"{c('[' + ts + ']', 'grey')} "
                f"{agent.ljust(8)}  {c(icon + ' working', color)}")
    elif state == "completed":
        line = (f"{c('[' + ts + ']', 'grey')} "
                f"{agent.ljust(8)}  {c(icon + ' completed', color)}   {c(extra, 'dim')}")
        if expand_artifacts and prompt:
            # prompt holds preview of artifact here
            line += f"\n  {c('└ ' + prompt[:200], 'dim')}"
    elif state in ("failed", "canceled", "rejected"):
        line = (f"{c('[' + ts + ']', 'grey')} "
                f"{agent.ljust(8)}  {c(icon + ' ' + state, color)}   {c(extra, 'dim')}  "
                f"{c('task=' + t_short, 'dim')}")
    else:
        line = (f"{c('[' + ts + ']', 'grey')} "
                f"{agent.ljust(8)}  {state}  task={t_short}")
    print(line, flush=True)

# ────── tasks.json watcher ──────
def snapshot(team):
    """Return {task_id: {state, agent, ts, prompt, artifact_preview}} for current tasks.json."""
    p = ROOT / team / "tasks.json"
    try: data = json.loads(p.read_text())
    except Exception: return {}
    snap = {}
    for t in data.get("tasks", []):
        tid = t.get("id")
        if not tid: continue
        st = t.get("status", {})
        hist = t.get("history") or []
        prompt = ""
        if hist and hist[0].get("parts"):
            for part in hist[0]["parts"]:
                if part.get("kind") == "text":
                    prompt = part.get("text", ""); break
        artifact_text = ""
        arts = t.get("artifacts") or []
        if arts and arts[0].get("parts"):
            for part in arts[0]["parts"]:
                if part.get("kind") == "text":
                    artifact_text = part.get("text", ""); break
        snap[tid] = {
            "state": st.get("state", "?"),
            "ts": st.get("timestamp", ""),
            "agent": t.get("_agent", "?"),
            "prompt": prompt,
            "artifact": artifact_text,
        }
    return snap

def diff_events(prev, now):
    """Return list of events representing changes from prev → now snapshot."""
    events = []
    for tid, cur in now.items():
        old = prev.get(tid)
        if old is None:
            # New task: emit both "submit" and the current state if it's not submitted
            events.append({
                "task_id": tid, "agent": cur["agent"], "state": "submit",
                "ts": cur["ts"], "prompt_preview": cur["prompt"],
            })
            if cur["state"] != "submitted":
                events.append(_terminal_event(tid, cur))
        elif old["state"] != cur["state"]:
            # State change
            if cur["state"] == "working":
                events.append({"task_id": tid, "agent": cur["agent"], "state": "working", "ts": cur["ts"]})
            else:
                events.append(_terminal_event(tid, cur))
    return events

def _terminal_event(tid, cur):
    state = cur["state"]
    ev = {"task_id": tid, "agent": cur["agent"], "state": state, "ts": cur["ts"]}
    if state == "completed":
        ev["extra"] = f"{len(cur['artifact'])} chars"
        ev["prompt_preview"] = cur["artifact"]  # for --expand-artifacts
    return ev

# ────── Keyboard listener (raw mode on tty) ──────
class KeyboardControl:
    def __init__(self):
        self.quit = False
        self.expand_artifacts = False
        self.clear_request = False
        self._orig_term = None
        self._tty = sys.stdin.isatty()

    def start(self):
        if not self._tty: return
        try:
            self._orig_term = termios.tcgetattr(sys.stdin.fileno())
            tty.setcbreak(sys.stdin.fileno())
            threading.Thread(target=self._loop, daemon=True).start()
        except Exception: self._orig_term = None

    def stop(self):
        if self._orig_term is not None:
            try: termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self._orig_term)
            except Exception: pass

    def _loop(self):
        while not self.quit:
            r, _, _ = select.select([sys.stdin], [], [], 0.3)
            if not r: continue
            ch = sys.stdin.read(1)
            if ch == "q": self.quit = True
            elif ch == "s": self.expand_artifacts = not self.expand_artifacts
            elif ch == "c": self.clear_request = True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("team")
    ap.add_argument("--poll-ms", type=int, default=800)
    ap.add_argument("--expand-artifacts", action="store_true")
    args = ap.parse_args()

    team = args.team
    if not (ROOT / team / "config.json").exists():
        sys.exit(f"team {team} not found at {ROOT/team}")

    kb = KeyboardControl(); kb.expand_artifacts = args.expand_artifacts; kb.start()

    # Header
    print(c(f"═══ mmteam a2a monitor · team={team} · (q=quit s=toggle-expand c=clear) ═══", "bold"))
    prev = snapshot(team)  # baseline — don't re-emit historical tasks
    # But announce what we found
    cnt = {}
    for t in prev.values(): cnt[t["state"]] = cnt.get(t["state"], 0) + 1
    if prev:
        summary = ", ".join(f"{k}={v}" for k, v in sorted(cnt.items()))
        print(c(f"  (baseline: {len(prev)} tasks, {summary})", "grey"))

    poll_s = args.poll_ms / 1000.0
    try:
        while not kb.quit:
            if kb.clear_request:
                sys.stdout.write("\x1b[2J\x1b[H")
                print(c(f"═══ mmteam a2a monitor · team={team} · (cleared) ═══", "bold"))
                kb.clear_request = False
            now = snapshot(team)
            events = diff_events(prev, now)
            for ev in events: emit(ev, kb.expand_artifacts)
            prev = now
            time.sleep(poll_s)
    except KeyboardInterrupt: pass
    finally:
        kb.stop()
        print(c("\n— monitor stopped —", "grey"))

if __name__ == "__main__":
    main()
