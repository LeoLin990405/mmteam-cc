#!/usr/bin/env bash
# install.sh — Install agent-bridge scripts to ~/.claude/bin/
#
# Idempotent: re-running just refreshes the symlinks.
# By default uses symlinks (so `git pull` immediately updates).
# Pass --copy for a hard copy install (no link to source repo).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$REPO_DIR/bin"
SKILL_SRC_DIR="$REPO_DIR/skills/agent-bridge"
DEST_DIR="${HOME}/.claude/bin"
SKILL_DEST_DIR="${HOME}/.claude/skills/agent-bridge"
MODE="link"

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE="copy"; shift ;;
    --link) MODE="link"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--link|--copy]
  --link  (default) symlink ~/.claude/bin/<script> → $SRC_DIR/<script>
  --copy  hard copy (lose auto-update via git pull)
EOF
      exit 0
      ;;
    *) echo "[install] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$SRC_DIR" ]; then
  echo "[install] source bin/ not found at $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

echo "[install] mode: $MODE   src: $SRC_DIR   dest: $DEST_DIR"
echo

count=0
for src in "$SRC_DIR"/*; do
  name=$(basename "$src")
  dest="$DEST_DIR/$name"
  if [ "$MODE" = "link" ]; then
    ln -sfn "$src" "$dest"
    echo "  link  $name"
  else
    cp -f "$src" "$dest"
    chmod +x "$dest"
    echo "  copy  $name"
  fi
  count=$((count + 1))
done

echo
echo "[install] installed $count scripts into $DEST_DIR"

# Install the agent-bridge Claude Code skill (so /skill agent-bridge works).
if [ -d "$SKILL_SRC_DIR" ]; then
  echo
  echo "[install] installing skill: agent-bridge → $SKILL_DEST_DIR"
  mkdir -p "$(dirname "$SKILL_DEST_DIR")"
  if [ "$MODE" = "link" ]; then
    ln -sfn "$SKILL_SRC_DIR" "$SKILL_DEST_DIR"
    echo "  link  $SKILL_DEST_DIR → $SKILL_SRC_DIR"
  else
    mkdir -p "$SKILL_DEST_DIR/references"
    cp -f "$SKILL_SRC_DIR/SKILL.md" "$SKILL_DEST_DIR/"
    cp -f "$SKILL_SRC_DIR/references/"*.md "$SKILL_DEST_DIR/references/" 2>/dev/null || true
    echo "  copy  $SKILL_DEST_DIR (SKILL.md + references/)"
  fi
fi

echo
echo "Verify:"
echo "  $DEST_DIR/agent-bridge --status"
echo "  # in Claude Code, the 'agent-bridge' skill should appear in /skill"
echo
echo "If ~/.claude/bin is not in PATH yet, add to ~/.zshrc or ~/.bashrc:"
echo "  export PATH=\"\$HOME/.claude/bin:\$PATH\""
