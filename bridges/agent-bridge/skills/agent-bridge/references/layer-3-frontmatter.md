# Layer 3 — Frontmatter routing reference

## Syntax

### Form A: YAML-style fence at the very top
```
---
@project: nd0044-fyyur
@thread: auto-new
@mode: gpt-5-codex
@timeout: 1200
---

Actual prompt body starts here.
```

### Form B: bare @key=val at the top (no fence)
```
@project=nd303-meme
@thread=current
@mode=workspace-write

Actual prompt body starts here.
```

Form B stops parsing at the first non-blank line that isn't `@key=val` or
`@key:val`. Either `:` or `=` separator works. Topic-style frontmatter
must be at the very top — comments/blank lines OK.

## Recognized keys (other keys are parsed but unused)

| Key | Maps to | Example |
|---|---|---|
| `project` | `ROUTE_PROJECT` | `nd0044-fyyur` (surface decides interpretation) |
| `thread`  | `ROUTE_THREAD`  | `auto-new` / `current` / specific id |
| `mode`    | `ROUTE_MODE`    | `gpt-5-codex` / `workspace-write` / `--max-turns 50` |
| `timeout` | `TIMEOUT_SEC`   | `1200` (overrides --timeout) |
| `agent`   | (informational; logged) | `Codex` / `Qoder` |
| `surface` | (informational) | hint for dispatcher (not enforced) |

## Precedence

```
CLI flag > frontmatter > unset
```

So `agent-bridge codex-cli review file.md --project X` overrides
`@project: Y` in the file. Test:

```
$ cat /tmp/r.md
---
@project: from-frontmatter
@mode: workspace-write
---
review please
$ agent-bridge codex-cli review /tmp/r.md --project from-cli
# → ROUTE_PROJECT=from-cli, ROUTE_MODE=workspace-write
```

## Injection

After parsing, the bridge writes the prompt with a `[Routing context]`
header injected at the top, then the body (frontmatter stripped):

```
[Routing context]
  Project: nd0044-fyyur
  Thread:  auto-new
  Mode:    gpt-5-codex
---
review please
```

The receiving agent sees this header and SHOULD operate on the named
target. Some surfaces can auto-switch (Codex App via CDP click sidebar);
others only show the context to the agent for it to act manually.

## Auto-switch capability matrix (Layer 2.5)

| Surface | --project auto-switch | --thread auto-switch | --mode auto-switch |
|---|---|---|---|
| codex-app | TODO: CDP click sidebar | TODO | partial: opencli codex model |
| codex-cli | N/A (stateless)        | N/A                  | yes: -s sandbox flag |
| antigravity | N/A (single thread) | N/A                  | yes: opencli antigravity model |
| qoder-cli | N/A (stateless)        | N/A                  | partial: --max-turns / --allowed-tools |
| trae-solo | TODO: CDP click task-list-group | TODO | N/A |

For now, Claude is expected to read the routing context from the agent's
reply and re-route manually if the agent says it operated on the wrong
target.

## Parser internals

Implementation: `~/.claude/bin/_frontmatter.py`. Three subcommands:

- `_frontmatter.py parse <file>` → `{"meta": {...}, "body_chars": N, "body_preview": "..."}`
- `_frontmatter.py strip <file>` → prints body only (used by bridges)
- `_frontmatter.py keys  <file>` → emits `META_KEY='val'` lines for `eval`

`_bridge_route.sh` sources these via `load_frontmatter_route()`.
