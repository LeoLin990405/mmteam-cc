#!/usr/bin/env bash
# _bridge_route.sh — Shared routing infrastructure sourced by every <surface>-bridge.sh.
#
# Provides 3 functions and 3 vars to each bridge:
#   ROUTE_PROJECT  — target project name (e.g. "nd0044-fyyur" or "/Users/leo")
#   ROUTE_THREAD   — target thread/session ("current" / "auto-new" / "<id>")
#   ROUTE_MODE     — target mode/model/sandbox (surface-specific)
#
#   parse_route_args   — pulls --project/--thread/--mode/--timeout out of "$@"
#                        leaving the remainder in $REST. Use INSIDE the bridge's
#                        existing parse_opts (call _both_ in sequence).
#   load_frontmatter_route <prompt-file>
#                      — reads @project / @thread / @mode from prompt file's
#                        frontmatter; CLI args take precedence (already-set
#                        ROUTE_* are NOT overwritten).
#   inject_routing_context <prompt-text>
#                      — prepends a `[Routing context]` header to the prompt
#                        so the receiving agent sees the routing decision.
#                        Returns the augmented prompt to stdout.
#
# Bridges that want to ACTUALLY switch (e.g. CDP-click a sidebar item) should
# additionally implement a per-surface `route_apply` function called after
# parse_route_args + load_frontmatter_route but before sending the prompt.

ROUTE_PROJECT=""
ROUTE_THREAD=""
ROUTE_MODE=""

parse_route_args() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)  ROUTE_PROJECT="$2";  shift 2 ;;
      --thread)   ROUTE_THREAD="$2";   shift 2 ;;
      --mode)     ROUTE_MODE="$2";     shift 2 ;;
      --timeout)  TIMEOUT_SEC="$2";    shift 2 ;;
      --max-turns) MAX_TURNS="$2";     shift 2 ;;
      *)          REST+=("$1");        shift ;;
    esac
  done
}

load_frontmatter_route() {
  local file="$1"
  [ -z "$file" ] || [ ! -f "$file" ] && return 0
  local helper="$HOME/.claude/bin/_frontmatter.py"
  [ ! -x "$helper" ] && return 0
  local kv
  while IFS= read -r kv; do
    [ -n "$kv" ] && eval "$kv" 2>/dev/null
  done < <("$helper" keys "$file" 2>/dev/null)
  # META_PROJECT / META_THREAD / META_MODE are now (potentially) set.
  # Only fill ROUTE_* if not already provided by CLI.
  [ -z "$ROUTE_PROJECT" ] && [ -n "${META_PROJECT:-}" ] && ROUTE_PROJECT="$META_PROJECT"
  [ -z "$ROUTE_THREAD" ]  && [ -n "${META_THREAD:-}" ]  && ROUTE_THREAD="$META_THREAD"
  [ -z "$ROUTE_MODE" ]    && [ -n "${META_MODE:-}" ]    && ROUTE_MODE="$META_MODE"
  [ -n "${META_TIMEOUT:-}" ] && TIMEOUT_SEC="$META_TIMEOUT"
}

strip_frontmatter() {
  local file="$1"
  local helper="$HOME/.claude/bin/_frontmatter.py"
  if [ -x "$helper" ] && [ -f "$file" ]; then
    "$helper" strip "$file"
  else
    cat "$file"
  fi
}

inject_routing_context() {
  local prompt="$1"
  if [ -z "$ROUTE_PROJECT" ] && [ -z "$ROUTE_THREAD" ] && [ -z "$ROUTE_MODE" ]; then
    printf "%s" "$prompt"
    return
  fi
  printf "[Routing context]\n"
  [ -n "$ROUTE_PROJECT" ] && printf "  Project: %s\n" "$ROUTE_PROJECT"
  [ -n "$ROUTE_THREAD" ]  && printf "  Thread:  %s\n" "$ROUTE_THREAD"
  [ -n "$ROUTE_MODE" ]    && printf "  Mode:    %s\n" "$ROUTE_MODE"
  printf '%s\n' "---"
  printf '%s' "$prompt"
}
