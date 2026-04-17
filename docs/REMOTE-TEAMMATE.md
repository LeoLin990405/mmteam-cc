# Remote Teammates — Cross-Host A2A

mmteam supports teammates running on a different machine. This enables scenarios like:
- Heavy inference on a Mac Studio while orchestrating from a MacBook
- Sharing a powerful GPU host among team members
- Separating compute from control

## Setup

### 1. On the remote host (server)

```bash
# Create and spawn a team
mmteam create remote-team kimi:kimi-code gem:gemini
mmteam a2a spawn remote-team

# Get the bearer token
jq -r '.kimi.bearer_token' ~/.claude/teams/remote-team/a2a-registry.json
# → e.g. a8f3b2c1-d4e5-6789-abcd-ef0123456789
```

The daemon listens on all interfaces by default. Note the host IP and port from the registry.

### 2. On the local host (client)

```bash
# Register the remote teammate
/mmteam:remote local-team kimi-remote http://studio.local:55723/ --token a8f3b2c1-d4e5-6789-abcd-ef0123456789

# Verify connectivity
mmteam a2a card local-team kimi-remote
# Should return the Agent Card JSON

# Use it like any local teammate
/mmteam:send local-team kimi-remote "Analyze this 200K token log"
```

### 3. Registry behavior

Remote teammates are stored in `a2a-registry.json` with `kind: "remote"`:

```json
{
  "kimi-remote": {
    "url": "http://studio.local:55723/",
    "bearer_token": "a8f3b2c1-...",
    "kind": "remote"
  }
}
```

**Important**: `mmteam a2a stop` on the local machine does NOT affect remote daemons. It only cleans up local teammates (`kind: "local"`).

## Security considerations

- **Bearer tokens** are plain-text in config files (`chmod 600` applied automatically)
- Traffic is **unencrypted HTTP** — suitable for trusted LAN / Tailscale / VPN
- For production deployments, put an HTTPS reverse proxy (nginx, caddy) in front
- Tokens are team-level (shared by all teammates in a team) — consider short-TTL rotation

## Discovery

Any A2A-compatible endpoint can be discovered:

```bash
mmteam a2a discover http://studio.local:55723/
# Returns the Agent Card with name, skills, capabilities
```

## Limitations

- **No push notifications** — polling only (A2A v0.3 subset)
- **No mTLS** — use network-level security instead
- **Log tailing** (`mmteam a2a follow`) only works for local teammates — remote logs stay on the remote host
- **Watch dashboard** shows remote teammates as entries but their panes will be empty (no local log to tail)
