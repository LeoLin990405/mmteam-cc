# Example: Watch Dashboard

Monitor all teammates' activity in real time via a cmux multi-pane dashboard.

## Prerequisites

- cmux installed (`brew install cmux`)

## Setup

```bash
mmteam create demo kimi:kimi-code gpt:codex gem:gemini
mmteam a2a spawn demo    # headless mode (no visual per teammate)
```

## Open the dashboard

```bash
mmteam a2a watch demo
```

This creates a cmux workspace `demo-watch` with:
- **Top strip**: `mmteam-a2a-monitor.py` showing task events
  ```
  [15:45:00] user → kimi   submit  "写快排"         task=abc123
  [15:45:03] kimi   ↻ working
  [15:45:08] kimi   ✓ completed  320 chars
  ```
- **Grid below**: one pane per teammate running `mmteam a2a follow`

## Use it

In another terminal (or Claude Code session), dispatch work:

```bash
mmteam a2a fanout demo "Explain RAFT consensus" --agents kimi,gpt,gem
```

Watch the dashboard — you'll see events flow in the top strip and stdout scroll in each teammate's pane.

## Close

```bash
mmteam a2a unwatch demo
```

## Without cmux

If cmux is not installed, you can still tail individual teammates:

```bash
mmteam a2a follow demo kimi    # in terminal 1
mmteam a2a follow demo gpt     # in terminal 2
mmteam a2a follow demo gem     # in terminal 3
```
