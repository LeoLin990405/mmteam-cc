#!/usr/bin/env bash
# sync-from-dev.sh — Vendor the latest ~/bin/mmteam* snapshot into repo bin/.
#
# Use case: maintainer iterates on ~/bin/mmteam locally. Before tagging a
# new release, run this to pull the latest scripts into the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${HOME}/bin"
DST="${ROOT}/bin"

FILES=(mmteam mmteam-a2a-server.py mmteam-a2a-monitor.py mmteam-mcp.py)

echo "mmteam-cc · sync from dev"
echo "  src : ${SRC}"
echo "  dst : ${DST}"
echo

CHANGED=0
for f in "${FILES[@]}"; do
  if [[ ! -f "${SRC}/${f}" ]]; then
    echo "  [MISS]  ${f}   (not in ${SRC})"
    continue
  fi
  if ! cmp -s "${SRC}/${f}" "${DST}/${f}"; then
    cp "${SRC}/${f}" "${DST}/${f}"
    chmod +x "${DST}/${f}"
    echo "  [SYNC]  ${f}   ($(wc -l < ${DST}/${f}) lines)"
    CHANGED=$((CHANGED+1))
  else
    echo "  [OK  ]  ${f}   (identical)"
  fi
done

echo
if [[ $CHANGED -gt 0 ]]; then
  echo "✓ ${CHANGED} file(s) updated. Run 'git diff bin/' to review, then commit."
else
  echo "✓ All in sync. Nothing to commit."
fi
