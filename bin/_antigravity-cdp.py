#!/usr/bin/env python3
# _antigravity-cdp.py — CDP probe for Antigravity.
#
# Antigravity is an Electron VSCode fork (Windsurf lineage). Like Trae SOLO,
# it requires --remote-allow-origins=* on launch for Chrome 142+ to permit
# external WebSocket connections to the CDP /devtools/page/<id> endpoints.
#
# This helper attaches to CDP port 9234, finds the main app target (filter
# out devtools / about:blank pages), and runs Runtime.evaluate to enumerate
# conversation-like DOM nodes for `agent-bridge antigravity list`.
#
# Usage:
#   _antigravity-cdp.py status [--port 9234]
#   _antigravity-cdp.py list   [--port 9234]
#
# Output: JSON to stdout. Errors as JSON {error: "..."} to stdout + exit 1.

from __future__ import annotations
import argparse
import json
import sys
import urllib.request
import urllib.error

try:
    import websocket  # type: ignore
except ImportError:
    print(json.dumps({"surface": "antigravity", "error": "websocket-client not installed for this python. Run: <python> -m pip install --break-system-packages websocket-client"}))
    sys.exit(1)


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

    def pick_target(self):
        """Pick the main Antigravity window (not devtools, not about:blank)."""
        targets = self._http_get_json("/json")
        # Score: prefer file:// or http(s):// URLs over devtools://about:blank
        def score(t):
            u = t.get("url", "")
            ty = t.get("type", "")
            s = 0
            if ty == "page":
                s += 100
            if u.startswith(("file://", "http://", "https://", "vscode-")):
                s += 50
            if "devtools" in u or u == "about:blank":
                s -= 200
            # workbench.html (VSCode-style) is the main UI
            if "workbench" in u.lower():
                s += 30
            return s
        targets = sorted(targets, key=score, reverse=True)
        if not targets:
            raise RuntimeError("no CDP targets")
        return targets[0]

    def connect(self):
        t = self.pick_target()
        self.target_url = t.get("url", "")
        self.target_title = t.get("title", "")
        ws_url = t.get("webSocketDebuggerUrl")
        if not ws_url:
            raise RuntimeError(f"no webSocketDebuggerUrl in target: {t.get('id')}")
        self._ws = websocket.create_connection(ws_url, timeout=10)

    def send(self, method: str, params: dict | None = None) -> dict:
        if self._ws is None:
            raise RuntimeError("not connected")
        msg = {"id": self._next_id(), "method": method, "params": params or {}}
        self._ws.send(json.dumps(msg))
        while True:
            raw = self._ws.recv()
            r = json.loads(raw)
            if r.get("id") == msg["id"]:
                if "error" in r:
                    raise RuntimeError(f"CDP error {method}: {r['error']}")
                return r.get("result", {})

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
            try:
                self._ws.close()
            except Exception:
                pass
            self._ws = None


def cmd_status(port: int):
    s = CDPSession(port)
    try:
        targets = s._http_get_json("/json")
        s.connect()
        ver = s._http_get_json("/json/version")
        out = {
            "surface": "antigravity",
            "cdp_port": port,
            "browser": ver.get("Browser", "?"),
            "ua_short": ver.get("User-Agent", "?")[:80],
            "ws_attached": True,
            "target_url": s.target_url[:120],
            "target_title": s.target_title[:80],
            "total_targets": len(targets),
        }
    except urllib.error.URLError as e:
        out = {"surface": "antigravity", "error": f"CDP not reachable on :{port}: {e}"}
    except Exception as e:
        out = {"surface": "antigravity", "error": f"{type(e).__name__}: {e}", "ws_attached": False}
    finally:
        s.close()
    print(json.dumps(out, indent=2, ensure_ascii=False))


def cmd_list(port: int):
    s = CDPSession(port)
    try:
        s.connect()
        # Enumerate conversation/thread-like DOM nodes with generic selectors.
        # Antigravity's actual selectors aren't documented; this scans for
        # candidate patterns used by Cursor/Windsurf-style chat UIs.
        js = r"""
(() => {
  const candidate_selectors = [
    '[class*="conversation"]',
    '[class*="thread"]',
    '[class*="chat-history"]',
    '[class*="chat-list"]',
    '[data-conversation-id]',
    '[data-thread-id]',
    '[data-session-id]',
    'aside [class*="item"]',
  ];
  const hits = {};
  for (const sel of candidate_selectors) {
    try {
      const nodes = document.querySelectorAll(sel);
      if (nodes.length > 0) {
        hits[sel] = {
          count: nodes.length,
          sample: Array.from(nodes).slice(0, 3).map(n => ({
            id: n.id || n.dataset?.conversationId || n.dataset?.threadId || n.dataset?.sessionId || null,
            cls: (n.className || '').toString().slice(0, 80),
            text_preview: (n.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80),
          })),
        };
      }
    } catch (e) {}
  }
  return {
    page_title: document.title,
    page_url: location.href,
    body_classes: (document.body?.className || '').toString().slice(0, 200),
    selector_hits: hits,
    body_text_chars: (document.body?.innerText || '').length,
  };
})()
"""
        probe = s.eval_js(js)
        sessions = []
        # If any conversation-like selector matched, list each as a session.
        for sel, info in (probe.get("selector_hits") or {}).items():
            for sample in info.get("sample", []):
                sessions.append({
                    "id": sample.get("id") or sample.get("text_preview", "")[:24],
                    "selector": sel,
                    "cls": sample.get("cls"),
                    "preview": sample.get("text_preview"),
                })
        out = {
            "surface": "antigravity",
            "active_session": "current",
            "sessions": sessions if sessions else [{"id": "current", "title": "(no conversation-like DOM nodes matched generic selectors)"}],
            "probe": {
                "page_title": probe.get("page_title"),
                "page_url": (probe.get("page_url") or "")[:120],
                "body_chars": probe.get("body_text_chars"),
                "selectors_matched": list((probe.get("selector_hits") or {}).keys()),
            },
            "note": "DOM probe via CDP ws. If selector_hits is empty, inspect Antigravity manually (Cmd+Shift+I) to find the chat-history selector.",
        }
    except urllib.error.URLError as e:
        out = {"surface": "antigravity", "error": f"CDP not reachable on :{port}: {e}", "fallback": True}
    except Exception as e:
        out = {"surface": "antigravity", "error": f"{type(e).__name__}: {e}", "fallback": True}
    finally:
        s.close()
    print(json.dumps(out, indent=2, ensure_ascii=False))
    if "error" in out:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for c in ("status", "list"):
        sp = sub.add_parser(c)
        sp.add_argument("--port", type=int, default=9234)
    args = p.parse_args()
    {"status": cmd_status, "list": cmd_list}[args.cmd](args.port)


if __name__ == "__main__":
    main()
