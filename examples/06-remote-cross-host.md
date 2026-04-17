# Example: Cross-Host Remote Teammate

Run teammates on a powerful remote machine, orchestrate from your laptop.

## On the remote host (Mac Studio)

```bash
# Create and spawn
mmteam create inference kimi:kimi-code gem:gemini
mmteam a2a spawn inference

# Get connection details
cat ~/.claude/teams/inference/a2a-registry.json | jq '{
  kimi_url: .kimi.url,
  kimi_token: .kimi.bearer_token,
  gem_url: .gem.url,
  gem_token: .gem.bearer_token
}'
```

## On the local host (MacBook)

```bash
# Create a local team (can include local + remote teammates)
mmteam create mixed local-gpt:codex
mmteam a2a spawn mixed

# Register remote teammates
mmteam a2a register mixed kimi-remote http://studio.local:55723/ \
  --token a8f3b2c1-d4e5-6789-abcd-ef0123456789

mmteam a2a register mixed gem-remote http://studio.local:55724/ \
  --token b9c4d3e2-f5a6-7890-bcde-f01234567890

# Verify
mmteam a2a ls mixed
# kimi-remote  http://studio.local:55723/  kind=remote  ✅
# gem-remote   http://studio.local:55724/  kind=remote  ✅
# local-gpt    http://127.0.0.1:55700/     kind=local   ✅

# Use as normal
mmteam a2a fanout mixed "Explain the Byzantine Generals Problem" \
  --agents kimi-remote,gem-remote,local-gpt
```

## Important notes

- `mmteam a2a stop mixed` only stops `local-gpt` — remote daemons are unaffected
- Log tailing (`follow`, `watch`) only works for local teammates
- Use Tailscale or VPN for network security (no built-in TLS)

## Cleanup

```bash
# Local
mmteam a2a stop mixed && mmteam destroy mixed

# Remote (SSH in)
ssh studio.local "mmteam a2a stop inference && mmteam destroy inference"
```
