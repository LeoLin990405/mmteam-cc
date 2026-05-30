#!/usr/bin/env bash
# discover-delete-selector.sh — Help find the "delete conversation" selector
# in any surface's UI by hovering a session row and dumping candidate buttons.
#
# Usage:
#   discover-delete-selector.sh codex-app    # uses port 9238
#   discover-delete-selector.sh trae-solo    # uses port 9235
#   discover-delete-selector.sh grok         # uses port 9237
#   discover-delete-selector.sh antigravity  # uses port 9234
#
# Output: JSON of all <button>s + icon-bearing elements visible RIGHT NOW.
# Workflow:
#   1. open the target app
#   2. hover the session row you want to delete (so the trash icon appears)
#   3. run this script within ~2s — it snapshots interactive elements
#   4. eyeball the JSON for the trash-icon button (look for aria-label / title)
#   5. tell Claude the selector; we wire it into the bridge's cmd_delete

set -euo pipefail

case "${1:-}" in
  codex-app)   PORT=9238 ;;
  trae-solo)   PORT=9235 ;;
  grok)        PORT=9237 ;;
  antigravity) PORT=9234 ;;
  *) echo "Usage: $0 <codex-app|trae-solo|grok|antigravity>" >&2; exit 2 ;;
esac

PYBIN=python3
for cand in "$HOME/.claude/bin/.venv/bin/python3" "$HOME/Projects/nd0044-fyyur/.venv/bin/python3"; do
  [ -x "$cand" ] && PYBIN="$cand" && break
done

"$PYBIN" <<PYEOF
import json, urllib.request, sys
try:
    import websocket
except ImportError:
    print(json.dumps({"error":"websocket-client not installed for $PYBIN"})); sys.exit(1)

PORT = $PORT
targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=3))
targets = [t for t in targets if t.get("type") == "page" and t.get("url","") not in ("about:blank","")]
if not targets:
    print(json.dumps({"error":"no page targets on port {}".format(PORT)})); sys.exit(1)
ws_url = targets[0]["webSocketDebuggerUrl"]
ws = websocket.create_connection(ws_url, timeout=8)

def send(method, params=None):
    msg = {"id": 1, "method": method, "params": params or {}}
    ws.send(json.dumps(msg))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == 1:
            return r.get("result", {})

probe = send("Runtime.evaluate", {
    "expression": r"""
(() => {
  // Capture all buttons + click-handler elements + icons currently in DOM.
  // Filter to ones with attrs that look like 'delete'/'trash'/'remove'/'discard'
  // OR ones inside a hovered ancestor (.hover, :hover, [data-hovered]).
  const inferDelete = (el) => {
    const txt = (el.textContent || '').toLowerCase().trim().slice(0, 30);
    const lbl = (el.getAttribute('aria-label') || '').toLowerCase();
    const ttl = (el.getAttribute('title') || '').toLowerCase();
    const cls = (el.className || '').toString().toLowerCase();
    const id  = (el.id || '').toLowerCase();
    const all = `${txt} ${lbl} ${ttl} ${cls} ${id}`;
    return /\b(delete|trash|remove|discard|del|删除|清除|drop|destroy)\b/.test(all);
  };

  const all_buttons = Array.from(document.querySelectorAll('button, [role="button"], [role="menuitem"], a[href="#"]'));
  const candidates = all_buttons.filter(inferDelete);

  // Also grab icons (svg / path) with delete-ish parents — sometimes the
  // trash icon is the visible element but the click handler is on a wrapper.
  const icons = Array.from(document.querySelectorAll('svg, [class*="icon"], [class*="Icon"]'));
  const icon_candidates = icons.filter(el => {
    let p = el.parentElement, hops = 0;
    while (p && hops < 4) {
      if (inferDelete(p)) return true;
      p = p.parentElement; hops++;
    }
    return false;
  });

  const summarize = (el) => ({
    tag: el.tagName.toLowerCase(),
    id: el.id || null,
    cls: (el.className || '').toString().slice(0, 100),
    aria_label: el.getAttribute('aria-label') || null,
    title: el.getAttribute('title') || null,
    text: (el.textContent || '').trim().slice(0, 50),
    data_attrs: Object.fromEntries(
      Array.from(el.attributes || [])
        .filter(a => a.name.startsWith('data-'))
        .slice(0, 5)
        .map(a => [a.name, a.value.slice(0, 50)])
    ),
    parent_cls: (el.parentElement?.className || '').toString().slice(0, 60),
  });

  return {
    page_url: location.href,
    button_candidates: candidates.slice(0, 20).map(summarize),
    icon_candidates: icon_candidates.slice(0, 10).map(summarize),
    note: 'If empty: trash icons typically appear ONLY on hover. Hover the session row in the UI then run this script within ~2 seconds.'
  };
})()
""",
    "returnByValue": True
})

print(json.dumps(probe.get("result",{}).get("value",{}), indent=2, ensure_ascii=False))
ws.close()
PYEOF
