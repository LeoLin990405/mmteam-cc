#!/usr/bin/env bash
# opencli-self-update.sh — Update opencli (npm pkg + fork sync).
#
# Three modes:
#   --check                 dry-run; just show what would happen
#   (no flag, default)      npm update if newer; sync fork main with upstream
#   --use-fork              ALSO: replace npm install with a symlink to the fork's
#                           local build (gives you adapters merged upstream but
#                           not yet npm-published). Builds the fork first.
#   --auto                  same as default but skips confirmation prompts
#                           (use in cron / from agent-bridge skill)
#
# Always backs up the prior install state to ~/.claude/opencli-backups/<ts>/
# so a bad update can be rolled back.
#
# Exit codes:
#   0 = OK, nothing changed OR successful update
#   1 = error
#   2 = update available but user declined

set -euo pipefail

NPM_PKG="@jackwener/opencli"
NPM_BASE="${HOME}/.npm-global/lib/node_modules/${NPM_PKG}"
FORK_DIR="${HOME}/Projects/OpenCLI"
BACKUP_DIR="${HOME}/.claude/opencli-backups"

MODE="default"
AUTO=0
USE_FORK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE="check"; shift ;;
    --use-fork) USE_FORK=1; shift ;;
    --auto)     AUTO=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "[update] unknown arg: $1" >&2; exit 2 ;;
  esac
done

confirm() {
  [ "$AUTO" = "1" ] && return 0
  echo -n "$1 [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

log() { echo "[opencli-update] $*"; }

# Step 0: current state
CUR_VERSION=$(node -e "console.log(require('$NPM_BASE/package.json').version)" 2>/dev/null || echo "(not installed)")
LATEST=$(npm view "$NPM_PKG" version 2>/dev/null || echo "?")

log "current : $CUR_VERSION"
log "latest  : $LATEST"

if [ "$MODE" = "check" ]; then
  if [ "$CUR_VERSION" = "$LATEST" ] && [ "$USE_FORK" = "0" ]; then
    log "✓ Up to date."
  else
    log "Would: npm i -g $NPM_PKG@$LATEST"
    if [ "$USE_FORK" = "1" ]; then
      log "Would: build fork at $FORK_DIR then npm link → override install"
    fi
  fi
  exit 0
fi

# Step 1: backup
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$TS"
mkdir -p "$BACKUP_PATH"
if [ -d "$NPM_BASE" ]; then
  log "backing up $NPM_BASE → $BACKUP_PATH (sans node_modules, just version + manifest)"
  cp "$NPM_BASE/package.json"      "$BACKUP_PATH/" 2>/dev/null || true
  cp "$NPM_BASE/cli-manifest.json" "$BACKUP_PATH/" 2>/dev/null || true
  ls -1 "$NPM_BASE/clis/" > "$BACKUP_PATH/clis-list-before.txt" 2>/dev/null || true
fi

# Step 2: npm update if newer
if [ "$CUR_VERSION" != "$LATEST" ]; then
  if confirm "Update $NPM_PKG: $CUR_VERSION → $LATEST?"; then
    log "running npm i -g $NPM_PKG@$LATEST..."
    npm i -g "$NPM_PKG@$LATEST" 2>&1 | tail -5
    NEW_VERSION=$(node -e "console.log(require('$NPM_BASE/package.json').version)" 2>/dev/null || echo "?")
    log "✓ updated to $NEW_VERSION"
  else
    log "⏭ skipped npm update"
    NEW_VERSION="$CUR_VERSION"
  fi
else
  log "✓ npm install already at latest ($LATEST)"
  NEW_VERSION="$CUR_VERSION"
fi

# Step 3: sync fork main with upstream
if [ -d "$FORK_DIR/.git" ]; then
  log "syncing fork at $FORK_DIR..."
  (
    cd "$FORK_DIR"
    git fetch upstream 2>&1 | tail -2
    CUR_BRANCH=$(git branch --show-current)
    if [ "$CUR_BRANCH" = "main" ]; then
      AHEAD=$(git rev-list --count upstream/main..HEAD)
      BEHIND=$(git rev-list --count HEAD..upstream/main)
      if [ "$BEHIND" -gt 0 ]; then
        if [ "$AHEAD" -gt 0 ]; then
          log "  ⚠ fork main is $AHEAD commits ahead AND $BEHIND behind upstream — manual merge."
        else
          log "  fast-forwarding fork main: $BEHIND new commits from upstream"
          git merge --ff-only upstream/main 2>&1 | tail -2
          git push origin main 2>&1 | tail -2 || true
        fi
      else
        log "  ✓ fork main already up-to-date with upstream"
      fi
    else
      log "  ℹ fork is on branch '$CUR_BRANCH', not main — skipping ff merge."
    fi
  )
fi

# Step 4: --use-fork (override npm with locally-built fork)
if [ "$USE_FORK" = "1" ]; then
  if [ ! -d "$FORK_DIR" ]; then
    log "✗ --use-fork requires $FORK_DIR" >&2
    exit 1
  fi
  if confirm "Build fork + npm link (replaces $NPM_PKG@$NEW_VERSION with fork HEAD)?"; then
    log "building fork..."
    ( cd "$FORK_DIR" && npm install 2>&1 | tail -3 && npm run build 2>&1 | tail -3 )
    log "creating npm link..."
    ( cd "$FORK_DIR" && npm link 2>&1 | tail -3 )
    log "✓ opencli now resolves to $FORK_DIR (via npm link)"
    log "  To revert: npm i -g $NPM_PKG@$LATEST"
  else
    log "⏭ skipped --use-fork build"
  fi
fi

# Step 5: post-update sanity check
log "verifying..."
if opencli --version >/dev/null 2>&1; then
  FINAL_VERSION=$(opencli --version 2>&1 | head -1 || echo "?")
  FINAL_COUNT=$(ls -1 "$NPM_BASE/clis/" 2>/dev/null | grep -v "^_\|test-utils" | wc -l | xargs)
  log "✓ opencli OK   version: $FINAL_VERSION   adapters: $FINAL_COUNT"
else
  log "✗ opencli broken after update!" >&2
  log "  Backup at: $BACKUP_PATH" >&2
  log "  Rollback: npm i -g $NPM_PKG@$CUR_VERSION" >&2
  exit 1
fi

log "done. backup: $BACKUP_PATH"
