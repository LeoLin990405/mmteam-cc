#!/usr/bin/env python3
# _grok-cdp.py — CDP driver for Grok web (https://grok.com).
#
# Architecture: independent Chrome instance launched by
# grok-launch-with-cdp.sh on port 9237 with its own --user-data-dir.
# Grok is a SPA — chat lives in DOM, no native API. We attach via CDP
# WebSocket, find the chat input/send button/response container with
# best-effort generic selectors, and use Runtime.evaluate to drive it.
#
# Selectors are CONFIG at the top of the file — update them when Grok's
# UI changes (Cmd+Shift+I in the Chrome window opened by the launcher).
#
# Usage:
#   _grok-cdp.py status [--port 9237]
#   _grok-cdp.py list   [--port 9237]      # probe current page / login state
#   _grok-cdp.py ask <prompt> [--port 9237] [--timeout 600] [--idle 8]
#   _grok-cdp.py probe-selectors [--port 9237]  # diagnostic: dump candidates

from __future__ import annotations
import argparse
import hashlib
import json
import sys
import time
import urllib.request
import urllib.error

try:
    import websocket  # type: ignore
except ImportError:
    print(json.dumps({
        "surface": "grok",
        "error": "websocket-client not installed for this python. Run: <python> -m pip install --break-system-packages websocket-client",
    }))
    sys.exit(1)


# ─── SELECTORS (update these when Grok's UI changes) ──────────────────
# Grok's chat input is a contenteditable, send button is identified by
# aria-label or data-testid. These are best-effort defaults; if they
# stop matching, run `probe-selectors` to find new candidates.
CHAT_INPUT_SELECTORS = [
    'textarea[placeholder*="Grok"]',
    'textarea[placeholder*="message"]',
    'textarea[placeholder*="ask"]',
    'textarea',                           # last resort
    '[contenteditable="true"][role="textbox"]',
    '[contenteditable="true"]',
]
SEND_BUTTON_SELECTORS = [
    'button[aria-label*="Send"]',
    'button[aria-label*="send"]',
    'button[data-testid*="send"]',
    'button[type="submit"]',
    'form button:last-child',             # last button in the input form
]
RESPONSE_NODE_SELECTORS = [
    '[data-message-author-role="assistant"]',
    'article[data-testid*="assistant"]',
    'article[data-testid*="message"]',
    '[class*="assistant-message"]',
    '[class*="bot-message"]',
    'main article',                       # generic
]
# ──────────────────────────────────────────────────────────────────────


class CDPSession:
    def __init__(self, port: int):
        self.port = port
        self._id = 0
        self._ws = None
        self.target_url = None
        self.target_title = None

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _http_get_json(self, path: str):
        url = f"http://127.0.0.1:{self.port}{path}"
        with urllib.request.urlopen(url, timeout=3) as r:
            return json.loads(r.read().decode("utf-8"))

    def pick_grok_target(self):
        """Pick the tab whose URL contains 'grok.com'."""
        targets = self._http_get_json("/json")
        # Prefer page-type, prefer URL containing grok
        def score(t):
            s = 0
            u = (t.get("url") or "")
            if t.get("type") == "page":
                s += 100
            if "grok.com" in u or "x.ai" in u:
                s += 50
            if u.startswith("devtools://") or u == "about:blank":
                s -= 200
            return s
        targets = sorted(targets, key=score, reverse=True)
        if not targets:
            raise RuntimeError("no CDP targets on port {}".format(self.port))
        chosen = targets[0]
        u = chosen.get("url", "")
        if "grok.com" not in u and "x.ai" not in u:
            raise RuntimeError(f"no grok.com tab found (best target URL: {u[:80]}). Open https://grok.com in the dedicated Chrome window.")
        return chosen

    def connect(self):
        t = self.pick_grok_target()
        self.target_url = t.get("url", "")
        self.target_title = t.get("title", "")
        ws_url = t.get("webSocketDebuggerUrl")
        if not ws_url:
            raise RuntimeError(f"no webSocketDebuggerUrl in target id={t.get('id')}")
        self._ws = websocket.create_connection(ws_url, timeout=10)

    def send(self, method: str, params: dict | None = None, timeout: float = 30) -> dict:
        if self._ws is None:
            raise RuntimeError("not connected")
        msg = {"id": self._next_id(), "method": method, "params": params or {}}
        self._ws.send(json.dumps(msg))
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._ws.settimeout(max(0.5, deadline - time.time()))
            try:
                raw = self._ws.recv()
            except Exception:
                continue
            r = json.loads(raw)
            if r.get("id") == msg["id"]:
                if "error" in r:
                    raise RuntimeError(f"CDP error {method}: {r['error']}")
                return r.get("result", {})
        raise TimeoutError(f"CDP {method} did not respond in {timeout}s")

    def eval_js(self, expr: str):
        r = self.send("Runtime.evaluate", {
            "expression": expr,
            "returnByValue": True,
            "awaitPromise": True,
        })
        res = r.get("result", {})
        if res.get("subtype") == "error":
            raise RuntimeError(f"JS eval error: {res.get('description', res)}")
        return res.get("value")

    def close(self):
        if self._ws is not None:
            try: self._ws.close()
            except Exception: pass
            self._ws = None


def cmd_status(port: int):
    s = CDPSession(port)
    try:
        targets = s._http_get_json("/json")
        ver = s._http_get_json("/json/version")
        s.connect()
        out = {
            "surface": "grok",
            "cdp_port": port,
            "browser": ver.get("Browser", "?"),
            "ws_attached": True,
            "target_url": s.target_url[:120],
            "target_title": s.target_title[:80],
            "total_targets": len(targets),
        }
    except urllib.error.URLError as e:
        out = {"surface": "grok", "error": f"CDP not reachable on :{port}: {e}", "hint": "Run grok-launch-with-cdp.sh first."}
    except Exception as e:
        out = {"surface": "grok", "error": f"{type(e).__name__}: {e}"}
    finally:
        s.close()
    print(json.dumps(out, indent=2, ensure_ascii=False))
    if "error" in out: sys.exit(1)


def cmd_list(port: int):
    """Best-effort enumerate: returns single 'current conversation' entry
    + login state probe."""
    s = CDPSession(port)
    try:
        s.connect()
        probe = s.eval_js(r"""
(() => {
  const conv_selectors = [
    'a[href*="/chat/"]',
    'a[href*="/c/"]',
    'nav a[href*="/grok"]',
    'aside li',
  ];
  const hits = {};
  for (const sel of conv_selectors) {
    try {
      const nodes = document.querySelectorAll(sel);
      if (nodes.length) {
        hits[sel] = Array.from(nodes).slice(0, 10).map(n => ({
          href: n.getAttribute('href') || null,
          text: (n.textContent || '').trim().slice(0, 60),
        }));
      }
    } catch (e) {}
  }
  const logged_in_signals = [
    !!document.querySelector('button[aria-label*="account"]'),
    !!document.querySelector('[data-testid*="user"]'),
    !!document.querySelector('img[alt*="avatar"]'),
    location.pathname !== '/login' && location.pathname !== '/',
  ];
  return {
    url: location.href,
    title: document.title,
    pathname: location.pathname,
    logged_in_signals,
    conv_hits: hits,
  };
})()
""")
        sessions = []
        for sel, items in (probe.get("conv_hits") or {}).items():
            for it in items:
                sessions.append({
                    "id": it.get("href") or it.get("text", "")[:30],
                    "selector": sel,
                    "preview": it.get("text"),
                })
        out = {
            "surface": "grok",
            "active_session": "current",
            "page_url": probe.get("url"),
            "page_title": probe.get("title"),
            "looks_logged_in": any(probe.get("logged_in_signals") or []),
            "sessions": sessions if sessions else [{"id": "current", "title": "(no conversation list elements matched; may need login)"}],
            "note": "Grok is a SPA — conversation list selectors are best-effort. probe-selectors helps tune them.",
        }
    except Exception as e:
        out = {"surface": "grok", "error": f"{type(e).__name__}: {e}"}
    finally:
        s.close()
    print(json.dumps(out, indent=2, ensure_ascii=False))
    if "error" in out: sys.exit(1)


def cmd_probe_selectors(port: int):
    """Diagnostic: try each chat/send/response selector and report which match."""
    s = CDPSession(port)
    try:
        s.connect()
        js = "(() => { const try_ = (lst) => lst.map(sel => { try { const ns = document.querySelectorAll(sel); return {sel, count: ns.length, sample: ns[0] ? (ns[0].outerHTML||'').slice(0,200) : null}; } catch(e) { return {sel, error: String(e)}; } }); return { chat_input: try_(%s), send_button: try_(%s), response_node: try_(%s) }; })()" % (
            json.dumps(CHAT_INPUT_SELECTORS), json.dumps(SEND_BUTTON_SELECTORS), json.dumps(RESPONSE_NODE_SELECTORS),
        )
        out = s.eval_js(js)
        print(json.dumps({"surface": "grok", "probe": out}, indent=2, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"surface": "grok", "error": f"{type(e).__name__}: {e}"}))
        sys.exit(1)
    finally:
        s.close()


def _pick_first_match(s: CDPSession, selectors: list) -> str | None:
    js = "(() => { const sels = %s; for (const sel of sels) { try { if (document.querySelector(sel)) return sel; } catch(e) {} } return null; })()" % json.dumps(selectors)
    return s.eval_js(js)


def cmd_ask(port: int, prompt: str, timeout: float, idle: float):
    s = CDPSession(port)
    try:
        s.connect()
        input_sel = _pick_first_match(s, CHAT_INPUT_SELECTORS)
        send_sel  = _pick_first_match(s, SEND_BUTTON_SELECTORS)
        resp_sel  = _pick_first_match(s, RESPONSE_NODE_SELECTORS)
        if not input_sel or not send_sel:
            raise RuntimeError(f"selectors not found — input={input_sel}, send={send_sel}. Run probe-selectors to tune.")

        # Fill input — use execCommand for contenteditable, value+input event for textarea.
        fill_js = """
(() => {
  const el = document.querySelector(%s);
  if (!el) return false;
  el.focus();
  if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set
                || Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    setter.call(el, %s);
  } else {
    // contenteditable
    document.execCommand('insertText', false, %s);
  }
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return true;
})()
""" % (json.dumps(input_sel), json.dumps(prompt), json.dumps(prompt))
        if not s.eval_js(fill_js):
            raise RuntimeError(f"fill failed for selector {input_sel}")

        # Click send.
        click_js = "(() => { const b = document.querySelector(%s); if (!b) return false; b.click(); return true; })()" % json.dumps(send_sel)
        if not s.eval_js(click_js):
            raise RuntimeError(f"click failed for selector {send_sel}")

        # Wait for response: poll the last assistant node's textContent until
        # `idle` seconds of no change, or `timeout` seconds total.
        deadline = time.time() + timeout
        last_text = ""
        last_change = time.time()
        first_seen_at = None
        while time.time() < deadline:
            time.sleep(0.6)
            cur_js = "(() => { const ns = document.querySelectorAll(%s); if (!ns.length) return ''; return (ns[ns.length-1].textContent || '').trim(); })()" % json.dumps(resp_sel)
            cur = s.eval_js(cur_js) or ""
            if cur and not first_seen_at:
                first_seen_at = time.time()
            if cur != last_text:
                last_text = cur
                last_change = time.time()
            elif cur and (time.time() - last_change) >= idle:
                break

        if not last_text:
            raise RuntimeError(f"no response captured from selector {resp_sel} within {timeout}s")
        print(last_text)
    except Exception as e:
        print(json.dumps({"surface": "grok", "error": f"{type(e).__name__}: {e}"}), file=sys.stderr)
        sys.exit(1)
    finally:
        s.close()


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for c in ("status", "list", "probe-selectors"):
        sp = sub.add_parser(c)
        sp.add_argument("--port", type=int, default=9237)
    spa = sub.add_parser("ask")
    spa.add_argument("prompt")
    spa.add_argument("--port", type=int, default=9237)
    spa.add_argument("--timeout", type=float, default=600)
    spa.add_argument("--idle", type=float, default=8)
    args = p.parse_args()
    if args.cmd == "ask":
        cmd_ask(args.port, args.prompt, args.timeout, args.idle)
    elif args.cmd == "probe-selectors":
        cmd_probe_selectors(args.port)
    else:
        {"status": cmd_status, "list": cmd_list}[args.cmd](args.port)


if __name__ == "__main__":
    main()
