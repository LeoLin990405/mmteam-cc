#!/usr/bin/env python3
# _trae-solo-cdp.py — Python WebSocket helper for trae-solo-bridge.sh.
#
# Talks to TRAE SOLO via CDP (port 9235) WebSocket because:
#   - opencli has no native trae-solo adapter
#   - opencli's `browser` subcommand needs an opencli-managed session bind
#   - Python websocket-client gives us a clean fill+click+wait+extract loop
#
# Usage:
#   _trae-solo-cdp.py status
#   _trae-solo-cdp.py ask "<prompt>" [--port 9235] [--timeout 600] [--idle 4]

import sys, json, time, hashlib, argparse
import urllib.request

try:
    import websocket  # websocket-client
except ImportError:
    print("ERROR: pip install websocket-client (or run from a venv that has it)", file=sys.stderr)
    sys.exit(1)


# ─── SELECTOR CONFIG (auto-detected via CDP query 2026-05-29) ────────
CHAT_INPUT = ".chat-input-v2-input-box-editable"      # Lexical contenteditable
SEND_BUTTON = ".chat-input-v2-send-button"            # has .disabled when input empty
MSG_LIST_ITEM = "[data-item-index]"  # Virtuoso virtual-list item; more reliable than __content > *
# ─────────────────────────────────────────────────────────────────────


def get_ws_url(port):
    raw = urllib.request.urlopen(f"http://localhost:{port}/json/list", timeout=2).read()
    for t in json.loads(raw):
        if t.get("type") == "page":
            return t["webSocketDebuggerUrl"]
    raise RuntimeError(f"no page target on :{port}")


def connect(port):
    return websocket.create_connection(get_ws_url(port), timeout=5)


class CDPSession:
    def __init__(self, ws):
        self.ws = ws
        self._mid = 0

    def evaluate(self, expr):
        self._mid += 1
        self.ws.send(json.dumps({
            "id": self._mid,
            "method": "Runtime.evaluate",
            "params": {"expression": expr, "returnByValue": True, "awaitPromise": True}
        }))
        while True:
            r = json.loads(self.ws.recv())
            if r.get("id") == self._mid:
                if "error" in r:
                    raise RuntimeError(f"CDP error: {r['error']}")
                return r.get("result", {}).get("result", {}).get("value")


def cmd_status(port):
    try:
        ws = connect(port)
    except Exception as e:
        print(f"✗ CDP :{port} unreachable: {e}", file=sys.stderr)
        return 1
    s = CDPSession(ws)
    state = s.evaluate(f"""
JSON.stringify({{
  input_present: !!document.querySelector('{CHAT_INPUT}'),
  send_btn_present: !!document.querySelector('{SEND_BUTTON}'),
  send_btn_class: (document.querySelector('{SEND_BUTTON}')||{{}}).className || null,
  msg_count: document.querySelectorAll('{MSG_LIST_ITEM}').length
}})
""")
    ws.close()
    print(f"✓ CDP :{port} connected")
    d = json.loads(state) if state else {}
    for k, v in d.items():
        mark = "✓" if (v is True or (isinstance(v, str) and v) or (isinstance(v, int) and v > 0)) else ("✗" if v is False else "·")
        print(f"  {mark} {k}: {v}")
    return 0


def fill_lexical(s, text):
    """Fill a Lexical contenteditable.
       Lexical listens for `beforeinput` events (not raw `paste`). The most
       reliable way to inject text is `document.execCommand('insertText', ...)`
       which generates a proper `beforeinput` → input flow. Falls back to
       CDP Input.insertText if execCommand returns false."""
    js = f"""
(() => {{
  const el = document.querySelector('{CHAT_INPUT}');
  if (!el) return 'no input';
  el.focus();
  // Select all + delete existing content
  const sel = window.getSelection();
  const r = document.createRange();
  r.selectNodeContents(el);
  sel.removeAllRanges();
  sel.addRange(r);
  document.execCommand('delete', false, null);
  // Insert new text — triggers beforeinput which Lexical listens for
  const ok = document.execCommand('insertText', false, {json.dumps(text)});
  // Verify it actually went in
  const filledText = (el.textContent || '').trim();
  return JSON.stringify({{
    execCommandOk: ok,
    filledChars: filledText.length,
    filledFirst30: filledText.slice(0, 30)
  }});
}})()
"""
    return s.evaluate(js)


def click_send(s):
    return s.evaluate(f"""
(() => {{
  const btn = document.querySelector('{SEND_BUTTON}');
  if (!btn) return 'no btn';
  if (btn.classList.contains('disabled')) return 'btn disabled';
  btn.click();
  return 'clicked';
}})()
""")


def get_msg_count(s):
    return s.evaluate(f"document.querySelectorAll('{MSG_LIST_ITEM}').length")


def get_last_msg_html(s):
    return s.evaluate(f"""
(() => {{
  const items = document.querySelectorAll('{MSG_LIST_ITEM}');
  return items.length ? items[items.length-1].outerHTML : '';
}})()
""") or ""


def get_last_msg_text(s):
    return s.evaluate(f"""
(() => {{
  const items = document.querySelectorAll('{MSG_LIST_ITEM}');
  return items.length ? (items[items.length-1].innerText || items[items.length-1].textContent || '') : '';
}})()
""") or ""


# Trae SOLO appends these markers to the last message when AI finishes streaming.
# Watch both English and Chinese UI variants.
DONE_MARKERS = ("Completed", "已完成", "Done")


def is_streaming_done(text):
    """True if last-message text ends with a Trae SOLO completion marker."""
    if not text:
        return False
    # Check last 80 chars — Trae SOLO sometimes appends action buttons after 'Completed'
    tail = text.rstrip()[-80:]
    return any(m in tail for m in DONE_MARKERS)


def strip_metadata(text):
    """Strip Trae SOLO's metadata wrapper around the AI response:
       <user prompt> / <timestamp> / SOLO Code / Worked for Ns / Thought / <REPLY> / Completed
       Returns the <REPLY> portion."""
    if not text:
        return text
    lines = [l for l in text.splitlines() if l.strip()]
    # Find 'Thought' marker (immediately before the AI response)
    start = None
    for i, l in enumerate(lines):
        if l.strip() in ("Thought", "思考"):
            start = i + 1
            break
    if start is None:
        return text  # no metadata wrapper detected; return as-is
    # Drop trailing completion marker
    end = len(lines)
    for j in range(len(lines) - 1, start, -1):
        if lines[j].strip() in DONE_MARKERS:
            end = j
            break
    return "\n".join(lines[start:end]).strip()


def cmd_ask(prompt, port, timeout, idle_seconds=30):
    ws = connect(port)
    s = CDPSession(ws)

    print(f"[ask] baseline msg count...", file=sys.stderr)
    baseline = get_msg_count(s)
    print(f"  baseline = {baseline}", file=sys.stderr)

    print(f"[ask] fill input via Lexical paste event...", file=sys.stderr)
    print(f"  -> {fill_lexical(s, prompt)}", file=sys.stderr)
    time.sleep(0.5)

    print(f"[ask] click send button...", file=sys.stderr)
    res = click_send(s)
    print(f"  -> {res}", file=sys.stderr)
    if res != "clicked":
        ws.close()
        print(f"FAIL: send button: {res}", file=sys.stderr)
        return 1

    print(f"[ask] wait for new message to appear (timeout {timeout}s)...", file=sys.stderr)
    start = time.time()
    while time.time() - start < timeout:
        cur = get_msg_count(s)
        if cur > baseline:
            print(f"  msg count {baseline} → {cur}", file=sys.stderr)
            break
        time.sleep(0.5)
    else:
        ws.close()
        print(f"FAIL: no new message after {timeout}s", file=sys.stderr)
        return 1

    print(f"[ask] poll for 'Completed' marker (idle {idle_seconds}s as fallback) ...", file=sys.stderr)
    last_hash = None
    stable_count = 0
    needed = int(idle_seconds / 0.5)
    while time.time() - start < timeout:
        text = get_last_msg_text(s)
        # Primary signal: Trae SOLO's "Completed" / "已完成" marker
        if is_streaming_done(text):
            print(f"  ✓ done marker found ({(text or '').rstrip()[-12:]!r})", file=sys.stderr)
            break
        # Fallback: hash idle
        html = get_last_msg_html(s)
        h = hashlib.md5((html or "").encode()).hexdigest()[:10]
        if h == last_hash:
            stable_count += 1
            if stable_count >= needed:
                print(f"  ✓ hash stable for {idle_seconds}s (fallback)", file=sys.stderr)
                break
        else:
            stable_count = 0
        last_hash = h
        time.sleep(0.5)

    print(f"[ask] extract response text (stripping Trae SOLO metadata wrapper)...", file=sys.stderr)
    raw = get_last_msg_text(s)
    text = strip_metadata(raw).strip()
    ws.close()
    print(text)
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status").add_argument("--port", type=int, default=9235)
    pa = sub.add_parser("ask")
    pa.add_argument("prompt")
    pa.add_argument("--port", type=int, default=9235)
    pa.add_argument("--timeout", type=int, default=600)
    pa.add_argument("--idle", type=int, default=30,
                    help="Fallback: how many seconds of stable DOM hash to treat as done (primary signal is 'Completed' marker)")
    args = p.parse_args()

    if args.cmd == "status":
        return cmd_status(args.port)
    elif args.cmd == "ask":
        return cmd_ask(args.prompt, args.port, args.timeout, args.idle)


if __name__ == "__main__":
    sys.exit(main())
