#!/usr/bin/env python3
# _inbox.py — Reverse-callback inbox for Layer 4 (child agent → parent Claude).
#
# When a bridge sends a prompt to a child agent (Codex / Antigravity / Trae /
# Qoder), the child can mark its reply with `@callback-claude:` lines (or a
# trailing `<<CALLBACK>> ... <<END>>` block). This helper extracts those
# markers from the response file and writes one inbox entry per callback to
#   ~/.claude/inbox/<ts>-<surface>-<topic>.md
#
# Claude (parent) polls ~/.claude/inbox with ScheduleWakeup or just `agent-bridge
# inbox list` at its convenience.
#
# Recognized callback formats inside the agent's reply:
#
#   Format A — single line:
#     @callback-claude: <message-text>
#
#   Format B — multi-line fenced block (use when message has newlines):
#     <<CALLBACK>>
#     Multi-line message here.
#     Can include code, tables, anything.
#     <<END>>
#
#   Format C — explicit topic:
#     @callback-claude[topic-slug]: <message>
#
# Usage:
#   _inbox.py extract <response-file> --surface <id> [--thread <id>]
#       parses callbacks from the file, writes inbox entries, prints summary JSON.
#   _inbox.py list   [--unread-only]
#       lists pending inbox entries.
#   _inbox.py read <entry-id-or-path>
#       prints an entry's body and marks it read (renames .md → .read.md).
#   _inbox.py clear [--older-than-hours N]
#       deletes read entries.

from __future__ import annotations
import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

INBOX_DIR = Path(os.environ.get("AGENT_BRIDGE_INBOX", os.path.expanduser("~/.claude/inbox")))
INBOX_DIR.mkdir(parents=True, exist_ok=True)

# Format A — single-line @callback-claude
_RE_LINE = re.compile(
    r"^@callback-claude(?:\[(?P<topic>[a-zA-Z0-9_-]+)\])?:\s*(?P<msg>.+?)\s*$",
    re.MULTILINE,
)
# Format B — fenced multi-line block
_RE_BLOCK = re.compile(
    r"<<CALLBACK(?:\[(?P<topic>[a-zA-Z0-9_-]+)\])?>>\s*\n(?P<msg>.*?)\n<<END>>",
    re.DOTALL,
)


def _slugify(s: str, maxlen: int = 30) -> str:
    s = re.sub(r"[^a-zA-Z0-9-]+", "-", s.strip())[:maxlen]
    return s.strip("-") or "msg"


def _ts() -> str:
    # Plain mtime-based timestamp — workflow scripts disallow Date.now() but
    # CLI scripts (this is one) are fine. Use os.time-equivalent via mktemp.
    return time.strftime("%Y%m%d-%H%M%S", time.localtime())


def cmd_extract(args):
    text = Path(args.response_file).read_text(encoding="utf-8", errors="replace")
    callbacks = []
    for m in _RE_LINE.finditer(text):
        callbacks.append({
            "topic": m.group("topic") or "",
            "msg": m.group("msg").strip(),
            "format": "line",
        })
    for m in _RE_BLOCK.finditer(text):
        callbacks.append({
            "topic": m.group("topic") or "",
            "msg": m.group("msg").strip(),
            "format": "block",
        })

    if not callbacks:
        print(json.dumps({
            "extracted": 0,
            "inbox_entries": [],
            "note": "No @callback-claude or <<CALLBACK>>...<<END>> markers found in response.",
        }, indent=2))
        return

    written = []
    ts = _ts()
    for i, cb in enumerate(callbacks):
        topic = cb["topic"] or _slugify(cb["msg"][:30]) or f"msg{i+1}"
        suffix = f"-{i+1}" if len(callbacks) > 1 else ""
        name = f"{ts}-{args.surface}-{topic}{suffix}.md"
        path = INBOX_DIR / name
        # If filename exists (rapid-fire), suffix with counter
        c = 0
        while path.exists():
            c += 1
            path = INBOX_DIR / f"{ts}-{args.surface}-{topic}{suffix}-{c}.md"
        body = (
            f"# Callback from {args.surface}\n\n"
            f"- ts: {ts}\n"
            f"- surface: {args.surface}\n"
            f"- thread: {args.thread or '(unspecified)'}\n"
            f"- topic: {topic}\n"
            f"- source_file: {args.response_file}\n"
            f"- format: {cb['format']}\n\n"
            f"---\n\n{cb['msg']}\n"
        )
        path.write_text(body, encoding="utf-8")
        written.append(str(path))

    print(json.dumps({
        "extracted": len(callbacks),
        "inbox_entries": written,
    }, indent=2))


def _list_entries(unread_only: bool):
    entries = []
    for p in sorted(INBOX_DIR.glob("*.md")):
        read = p.name.endswith(".read.md")
        if unread_only and read:
            continue
        st = p.stat()
        entries.append({
            "path": str(p),
            "name": p.name,
            "read": read,
            "size": st.st_size,
            "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime)),
        })
    return entries


def cmd_list(args):
    entries = _list_entries(args.unread_only)
    print(json.dumps({
        "inbox_dir": str(INBOX_DIR),
        "total": len(entries),
        "entries": entries,
    }, indent=2))


def cmd_read(args):
    p = Path(args.entry_id)
    if not p.is_absolute():
        # Try matching as filename in inbox dir
        matches = list(INBOX_DIR.glob(f"*{args.entry_id}*"))
        if len(matches) == 1:
            p = matches[0]
        elif len(matches) > 1:
            print(json.dumps({"error": f"ambiguous: {len(matches)} matches", "matches": [str(m) for m in matches]}))
            sys.exit(2)
        else:
            print(json.dumps({"error": f"no entry matching {args.entry_id} in {INBOX_DIR}"}))
            sys.exit(2)
    if not p.exists():
        print(json.dumps({"error": f"not found: {p}"}))
        sys.exit(2)

    sys.stdout.write(p.read_text(encoding="utf-8"))
    sys.stdout.write("\n")

    if not p.name.endswith(".read.md"):
        new_name = p.name[:-3] + ".read.md"
        p.rename(p.with_name(new_name))


def cmd_clear(args):
    cutoff = time.time() - (args.older_than_hours * 3600)
    removed = 0
    for p in INBOX_DIR.glob("*.read.md"):
        if p.stat().st_mtime < cutoff:
            p.unlink()
            removed += 1
    print(json.dumps({"removed": removed, "remaining": len(_list_entries(False))}, indent=2))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    spe = sub.add_parser("extract")
    spe.add_argument("response_file")
    spe.add_argument("--surface", required=True)
    spe.add_argument("--thread", default=None)
    spe.set_defaults(func=cmd_extract)

    spl = sub.add_parser("list")
    spl.add_argument("--unread-only", action="store_true")
    spl.set_defaults(func=cmd_list)

    spr = sub.add_parser("read")
    spr.add_argument("entry_id", help="filename, slug, or absolute path")
    spr.set_defaults(func=cmd_read)

    spc = sub.add_parser("clear")
    spc.add_argument("--older-than-hours", type=int, default=24)
    spc.set_defaults(func=cmd_clear)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
