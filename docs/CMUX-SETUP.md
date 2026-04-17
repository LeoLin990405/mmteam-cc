# cmux Setup (Optional)

cmux is a terminal multiplexer with workspace support. mmteam uses it for:
- **Dock mode** (`--dock`): visual multi-pane grid showing each teammate's CLI TUI
- **Monitor strip** (`--monitor`): top bar with colored task state transitions
- **Watch dashboard** (`/mmteam:watch`): independent observability workspace

## Without cmux

Everything works in **headless mode** by default — no cmux needed:
- `mmteam a2a spawn <team>` — background daemons, no visual
- `mmteam a2a follow <team> <agent>` — tail daemon log in current terminal
- `mmteam a2a send/fanout/pipeline` — all fully functional
- Set `MMTEAM_NO_CMUX=1` to suppress cmux-related warnings

## Installing cmux

cmux is available via Homebrew (macOS) or from source:

```bash
# macOS
brew install cmux

# Verify
cmux --version
cmux ping
```

## Using dock mode

```bash
mmteam a2a spawn myteam --dock
# Opens cmux workspace "myteam-a2a" with N panes

mmteam a2a spawn myteam --dock --monitor
# Same + top strip showing event timeline
```

### Layout (auto-adaptive to teammate count)

| Teammates | Layout |
|---|---|
| 1 | Single pane |
| 2 | Side by side |
| 3 | Left + right column (top/bottom) |
| 4 | 2×2 grid |
| 5 | 3 columns, left has 2 rows |
| 6 | 2×3 grid |
| ≥7 | Rejected — use headless |

### Navigation

Switch between workspaces using your cmux keybindings. Each team gets its own isolated workspace.

## Watch dashboard

```bash
/mmteam:watch myteam
# Creates separate workspace "myteam-watch"
# Top pane: mmteam-a2a-monitor.py (event stream)
# Grid: one pane per teammate running `mmteam a2a follow`

/mmteam:unwatch myteam
# Closes the watch workspace
```

Watch works independently of dock mode — you can have teammates running headless while watching their output in the dashboard.

## Troubleshooting

| Issue | Fix |
|---|---|
| `cmux: command not found` | Install cmux or use headless mode |
| Workspace not appearing | `cmux list-workspaces` to see all, switch manually |
| Panes showing errors | Teammates may not be spawned yet — spawn first, watch second |
| Layout looks wrong | Close stale workspaces: `cmux close-workspace --workspace ws:N` |
