# Keeping opencli current

`agent-bridge` is built on top of `@jackwener/opencli` — the upstream project
ships new adapters (websites/apps it can drive) on a weekly-ish cadence.
Since we depend on it heavily, two scripts keep the local install fresh.

## One-shot: check what's available

```
agent-bridge inventory
```

Shows:
- which version is on `PATH` (npm install)
- which version is the upstream latest on npm
- adapter counts: installed vs fork-main vs upstream-latest
- the diff: which adapters fork has but installed doesn't
- a recommendation (no-op / npm-update / fork-build)

Sample output (2026-05-30):

```
Installed (used by 'opencli' on PATH):
  version       : 1.8.0
  installed     : 2026-05-21
  adapter count : 150

Upstream npm latest:
  version       : 1.8.0

Fork (your working copy):
  HEAD          : 545754d8 fix(launcher): add --remote-allow-origins=*
  adapter count : 155
  ahead of upstream/main: 1 commit(s)
  behind upstream/main : 0 commit(s)

Adapters fork has but installed doesn't (will appear after update):
  + chess
  + confluence
  + geogebra
  + jira
  + upwork
```

## One-shot: update

Interactive (will confirm):
```
agent-bridge update              # npm i -g @jackwener/opencli@latest + sync fork
```

Dry-run:
```
agent-bridge update --check
```

Skip prompts (use in cron / from a skill):
```
agent-bridge update --auto
```

Override npm install with your locally-built fork (gives you adapters merged
upstream but not yet npm-published):
```
agent-bridge update --use-fork
# To revert: npm i -g @jackwener/opencli@latest
```

Every update writes a backup of `package.json` + `cli-manifest.json` +
`clis-list-before.txt` to `~/.claude/opencli-backups/<timestamp>/`. If an
update breaks something, roll back with the version printed at the start of
the update run.

## Background auto-update (optional, macOS launchd)

If you want opencli kept current without thinking about it, install a weekly
launchd agent. This template runs `update --check` every Monday at 09:00 and
extracts a callback to the bridge inbox if there's a new version — Claude (or
you) sees it next time you check `agent-bridge inbox list`.

Save as `~/Library/LaunchAgents/com.leo.opencli-update-check.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.leo.opencli-update-check</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>OUT=$(/Users/leo/.claude/bin/opencli-self-update.sh --check 2>&amp;1) ; echo "$OUT" | grep -q "Up to date" || echo -e "@callback-claude[opencli-update]: $OUT" > /tmp/opencli-update-callback.md &amp;&amp; /Users/leo/.claude/bin/_inbox.py extract /tmp/opencli-update-callback.md --surface meta --thread auto</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>1</integer>
    <key>Hour</key><integer>9</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>/tmp/opencli-update-check.log</string>
  <key>StandardErrorPath</key><string>/tmp/opencli-update-check.err</string>
</dict>
</plist>
```

Load with:
```
launchctl load ~/Library/LaunchAgents/com.leo.opencli-update-check.plist
```

Unload (stop checking):
```
launchctl unload ~/Library/LaunchAgents/com.leo.opencli-update-check.plist
```

## Why two layers (npm install + fork)?

- **npm install** is the source-of-truth for what `opencli` on `PATH` runs.
  Most users only ever touch this — `agent-bridge update` keeps it current.

- **The fork** (`~/Projects/OpenCLI`) exists for two reasons:
  1. We've submitted PRs upstream (e.g. the Chromium 142 ws origin fix,
     the antigravity serve.js import path fix). Until those merge + ship
     to npm, the fork carries them.
  2. The fork also catches adapters merged to `jackwener/main` between
     npm releases. `--use-fork` lets you opt into those early.

Sync the fork with upstream:
```
cd ~/Projects/OpenCLI && git fetch upstream && git merge --ff-only upstream/main
```
(The `update` script does this automatically when fork main has no local
commits ahead of upstream.)
