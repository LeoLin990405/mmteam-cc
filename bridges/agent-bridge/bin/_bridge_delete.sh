#!/usr/bin/env bash
# _bridge_delete.sh — Shared delete-confirmation helpers.
# Source from any bridge that implements cmd_delete.
#
# Convention:
#   - default behavior is --dry-run (show what WOULD be deleted, don't act)
#   - --yes (or -y) actually performs the deletion
#   - --all  delete every session (must be combined with --yes)
#   - <id>   delete a specific session by id

# Globals set by parse_delete_args:
DELETE_ID=""
DELETE_ALL=0
DELETE_YES=0
DELETE_DRY_RUN=1

parse_delete_args() {
  DELETE_ID=""
  DELETE_ALL=0
  DELETE_YES=0
  DELETE_DRY_RUN=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)      DELETE_ALL=1; shift ;;
      --yes|-y)   DELETE_YES=1; DELETE_DRY_RUN=0; shift ;;
      --dry-run)  DELETE_DRY_RUN=1; shift ;;
      -h|--help)
        cat <<EOF >&2
delete usage:
  delete <session-id>       — delete one session (defaults to dry-run)
  delete --all              — delete all sessions (always requires --yes too)
  delete <id> --yes         — actually delete (otherwise dry-run)
  delete --all --yes        — actually delete all
EOF
        exit 0
        ;;
      --*)        echo "[delete] unknown option: $1" >&2; exit 2 ;;
      *)          DELETE_ID="$1"; shift ;;
    esac
  done

  if [ "$DELETE_ALL" = "1" ] && [ "$DELETE_YES" != "1" ]; then
    # --all without --yes → force dry-run; safety guard.
    DELETE_DRY_RUN=1
  fi
}

# Print a banner to stderr.
delete_banner() {
  local surface="$1" action="$2" target="$3"
  if [ "$DELETE_DRY_RUN" = "1" ]; then
    echo "[delete:dry-run] $surface would $action: $target" >&2
    echo "[delete:dry-run] re-run with --yes to actually delete." >&2
  else
    echo "[delete] $surface will $action: $target" >&2
  fi
}
