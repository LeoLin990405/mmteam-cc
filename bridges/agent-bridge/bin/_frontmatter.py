#!/usr/bin/env python3
# _frontmatter.py — Parse @key=val routing metadata from prompt files.
#
# Recognized formats (both work):
#
#   1. YAML-style frontmatter at top of file:
#      ---
#      @project: nd0044-fyyur
#      @thread: auto-new
#      @mode: gpt-5-codex
#      ---
#      Actual prompt content...
#
#   2. Inline @key=val on the first few lines (no fence):
#      @project=nd0044-fyyur
#      @thread=auto-new
#
#      Actual prompt content...
#
# Usage:
#   _frontmatter.py parse <file>      → JSON {meta: {...}, body: "..."}
#   _frontmatter.py strip <file>      → prints body only (frontmatter removed)
#   _frontmatter.py keys  <file>      → prints recognized routing keys as KEY=VAL lines for `eval`

import sys
import json
import re
import argparse
from pathlib import Path


_AT_KV_RE = re.compile(r"^@([a-zA-Z][a-zA-Z0-9_-]*)\s*[:=]\s*(.+?)\s*$")
KNOWN_KEYS = {"project", "thread", "mode", "agent", "surface", "timeout"}


def parse(text):
    """Returns (meta_dict, body_str)."""
    lines = text.splitlines(keepends=False)
    meta = {}

    # Format 1: --- ... --- fenced YAML-style block at the very top
    if lines and lines[0].strip() == "---":
        end = None
        for i in range(1, min(len(lines), 30)):
            if lines[i].strip() == "---":
                end = i
                break
        if end is not None:
            for ln in lines[1:end]:
                m = _AT_KV_RE.match(ln.strip())
                if m:
                    meta[m.group(1)] = m.group(2)
            body_lines = lines[end + 1 :]
            # Strip leading blank lines
            while body_lines and not body_lines[0].strip():
                body_lines.pop(0)
            return meta, "\n".join(body_lines)

    # Format 2: bare @key=val lines at top until first non-matching, non-blank line
    body_start = 0
    for i, ln in enumerate(lines):
        s = ln.strip()
        if not s:
            continue
        m = _AT_KV_RE.match(s)
        if m:
            meta[m.group(1)] = m.group(2)
            body_start = i + 1
        else:
            break

    body_lines = lines[body_start:]
    while body_lines and not body_lines[0].strip():
        body_lines.pop(0)
    return meta, "\n".join(body_lines)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("parse")
    sp.add_argument("file")
    sps = sub.add_parser("strip")
    sps.add_argument("file")
    spk = sub.add_parser("keys")
    spk.add_argument("file")
    args = p.parse_args()

    text = Path(args.file).read_text(encoding="utf-8")
    meta, body = parse(text)

    if args.cmd == "parse":
        print(json.dumps({"meta": meta, "body_chars": len(body), "body_preview": body[:200]}, ensure_ascii=False))
    elif args.cmd == "strip":
        sys.stdout.write(body)
    elif args.cmd == "keys":
        # Output shell-eval friendly: META_<KEY>='val'
        for k, v in meta.items():
            kk = k.upper().replace("-", "_")
            # Single-quote-safe escaping
            vv = v.replace("'", "'\\''")
            print(f"META_{kk}='{vv}'")


if __name__ == "__main__":
    main()
