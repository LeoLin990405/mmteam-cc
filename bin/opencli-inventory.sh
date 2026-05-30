#!/usr/bin/env bash
# opencli-inventory.sh — Report installed vs available opencli adapters.
#
# Shows:
#   - Which @jackwener/opencli version is on PATH (npm install)
#   - Which version is the upstream latest on npm
#   - Adapter counts: installed vs fork-main vs upstream-latest
#   - The diff: which adapters fork has but installed doesn't
#
# Usage:
#   opencli-inventory.sh
#   opencli-inventory.sh --json     # machine-readable

set -euo pipefail

NPM_BASE="${HOME}/.npm-global/lib/node_modules/@jackwener/opencli"
FORK_DIR="${HOME}/Projects/OpenCLI"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

# 1. Installed version
if [ -d "$NPM_BASE" ]; then
  INSTALLED_VERSION=$(node -e "console.log(require('$NPM_BASE/package.json').version)" 2>/dev/null || echo "?")
  INSTALLED_DATE=$(stat -f '%Sm' -t '%Y-%m-%d' "$NPM_BASE/package.json" 2>/dev/null || echo "?")
  INSTALLED_COUNT=$(ls -1 "$NPM_BASE/clis/" 2>/dev/null | grep -v "^_\|test-utils" | wc -l | xargs)
else
  INSTALLED_VERSION="(not installed)"
  INSTALLED_DATE="-"
  INSTALLED_COUNT=0
fi

# 2. Upstream latest
UPSTREAM_VERSION=$(npm view @jackwener/opencli version 2>/dev/null || echo "?")

# 3. Fork status
FORK_COUNT=0
FORK_HEAD=""
FORK_AHEAD_OF_UPSTREAM=""
if [ -d "$FORK_DIR/.git" ]; then
  FORK_COUNT=$(ls -1 "$FORK_DIR/clis/" 2>/dev/null | grep -v "^_\|test-utils" | wc -l | xargs)
  FORK_HEAD=$(cd "$FORK_DIR" && git log -1 --format='%h %s' 2>/dev/null | cut -c 1-60)
  # Behind/ahead vs origin/upstream
  if cd "$FORK_DIR" && git fetch upstream 2>/dev/null; then
    FORK_AHEAD_OF_UPSTREAM=$(cd "$FORK_DIR" && git rev-list --count upstream/main..HEAD 2>/dev/null || echo "?")
    FORK_BEHIND_UPSTREAM=$(cd "$FORK_DIR" && git rev-list --count HEAD..upstream/main 2>/dev/null || echo "?")
  fi
fi

# 4. Diff
ADAPTER_DIFF=""
NEW_IN_FORK=""
if [ -d "$NPM_BASE/clis" ] && [ -d "$FORK_DIR/clis" ]; then
  _DIFF=$(diff \
    <(ls -1 "$NPM_BASE/clis/" | grep -v "^_\|test-utils" | sort) \
    <(ls -1 "$FORK_DIR/clis/" | grep -v "^_\|test-utils" | sort) || true)
  NEW_IN_FORK=$(echo "$_DIFF" | grep '^>' | sed 's/> //' | tr '\n' ',' | sed 's/,$//' || true)
  REMOVED_IN_FORK=$(echo "$_DIFF" | grep '^<' | sed 's/< //' | tr '\n' ',' | sed 's/,$//' || true)
fi

# Determine recommendation
UPDATE_RECOMMENDED="no"
RECO_REASON=""
if [ "$INSTALLED_VERSION" != "$UPSTREAM_VERSION" ] && [ "$UPSTREAM_VERSION" != "?" ]; then
  UPDATE_RECOMMENDED="yes"
  RECO_REASON="installed $INSTALLED_VERSION → upstream $UPSTREAM_VERSION"
elif [ "$FORK_COUNT" -gt "$INSTALLED_COUNT" ] 2>/dev/null; then
  UPDATE_RECOMMENDED="fork-build"
  RECO_REASON="fork main has $((FORK_COUNT - INSTALLED_COUNT)) new adapters vs installed npm; consider 'npm link' from fork"
fi

if [ "$JSON" = "1" ]; then
python3 <<PYEOF
import json
print(json.dumps({
  "installed": {
    "version": "$INSTALLED_VERSION",
    "installed_date": "$INSTALLED_DATE",
    "adapter_count": $INSTALLED_COUNT,
    "path": "$NPM_BASE",
  },
  "upstream_latest": {
    "version": "$UPSTREAM_VERSION",
  },
  "fork": {
    "path": "$FORK_DIR",
    "head": "$FORK_HEAD",
    "adapter_count": $FORK_COUNT,
    "ahead_of_upstream": "$FORK_AHEAD_OF_UPSTREAM",
    "behind_upstream": "${FORK_BEHIND_UPSTREAM:-?}",
  },
  "new_in_fork_vs_installed": "$NEW_IN_FORK".split(",") if "$NEW_IN_FORK" else [],
  "removed_in_fork_vs_installed": "$REMOVED_IN_FORK".split(",") if "$REMOVED_IN_FORK" else [],
  "update_recommended": "$UPDATE_RECOMMENDED",
  "reason": "$RECO_REASON",
}, indent=2))
PYEOF
else
  cat <<EOF
═══ opencli inventory ═══

Installed (used by 'opencli' on PATH):
  version       : $INSTALLED_VERSION
  installed     : $INSTALLED_DATE
  adapter count : $INSTALLED_COUNT
  path          : $NPM_BASE

Upstream npm latest:
  version       : $UPSTREAM_VERSION

Fork (your working copy):
  path          : $FORK_DIR
  HEAD          : $FORK_HEAD
  adapter count : $FORK_COUNT
  ahead of upstream/main: $FORK_AHEAD_OF_UPSTREAM commit(s)
  behind upstream/main : ${FORK_BEHIND_UPSTREAM:-?} commit(s)

Adapters fork has but installed doesn't (will appear after update):
EOF
  if [ -n "$NEW_IN_FORK" ]; then
    echo "$NEW_IN_FORK" | tr ',' '\n' | sed 's/^/  + /'
  else
    echo "  (none)"
  fi
  if [ -n "$REMOVED_IN_FORK" ]; then
    echo
    echo "Adapters installed has but fork doesn't (were removed upstream):"
    echo "$REMOVED_IN_FORK" | tr ',' '\n' | sed 's/^/  - /'
  fi

  echo
  echo "═══ Recommendation ═══"
  case "$UPDATE_RECOMMENDED" in
    yes)
      echo "  ✓ npm has a newer version. Run:"
      echo "      opencli-self-update.sh"
      echo "    Reason: $RECO_REASON"
      ;;
    fork-build)
      echo "  ⚠ npm version matches installed, but fork main has $((FORK_COUNT - INSTALLED_COUNT)) extra adapter(s)."
      echo "    These were merged upstream but not yet released to npm. Options:"
      echo "      A. wait for next npm release"
      echo "      B. opencli-self-update.sh --use-fork    # symlink your fork's build over the npm install"
      ;;
    no)
      echo "  ✓ Installed matches upstream npm latest. No update needed."
      ;;
  esac
fi
