---
description: Register a remote teammate running on another host
argument-hint: '<team-name> <agent-id> <url> --token <bearer-token>'
context: fork
allowed-tools: Bash(node:*, mmteam:*)
---

Add a remote teammate to this team's registry. The teammate must already be running an `mmteam-a2a-server.py` daemon on the remote host (e.g. Mac Studio) and you need its URL + bearer token.

Steps on the remote host:
```bash
mmteam a2a spawn <team>
jq -r '.<agent>.bearer_token' ~/.claude/teams/<team>/a2a-registry.json
```

Then locally:
```
/mmteam:remote <team> <agent>-remote http://studio.local:55723/ --token <TOKEN>
/mmteam:send <team> <agent>-remote "..."
```

The remote teammate is listed with `kind=remote` — `stop` and `destroy` on the local machine do not affect it. See docs/REMOTE-TEAMMATE.md.

Raw user args:
$ARGUMENTS

Run: `node "${CLAUDE_PLUGIN_ROOT}/scripts/mmteam-bridge.mjs" a2a register $ARGUMENTS`
