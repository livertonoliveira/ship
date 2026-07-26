#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# driver-local.sh — plain `git worktree` + in-context Agents. No external
# runtime, so it works anywhere git does; the cost is that the workers run
# inside the orchestrator's own turn instead of independently.
#
# Because Agent calls are synchronous, `wait` has nothing to block on: by the
# time the graph asks, every Agent dispatched in the previous turn has already
# returned. `wait` therefore reports exactly the tasks this driver dispatched.
#
# Workspaces are created OUTSIDE the repo (../.ship-graph/<feature>/<task>).
# Nesting them under .context/ would put whole extra checkouts inside the tree
# the merge node runs the full test suite over — the runner would collect their
# test files too.
#
# Verbs: dispatch | collect | wait | ask | stop  (contract in driver-manual.sh)
# ---------------------------------------------------------------------------

usage() {
  echo "usage: driver-local.sh <dispatch|collect|wait|ask|stop> [args...]" >&2
}

STATE=""
REPO=""
BASE=""
TASK=""

parse_flags() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) STATE="$2"; shift 2 ;;
      --repo) REPO="$2"; shift 2 ;;
      --base) BASE="$2"; shift 2 ;;
      --task) TASK="$2"; shift 2 ;;
      --timeout-ms) shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) REST+=("$1"); shift ;;
    esac
  done
}

require_state() {
  [ -n "$STATE" ] || { echo "driver-local.sh: --state <dir> is required" >&2; exit 1; }
  mkdir -p "$STATE"
}

workspace_root() {
  local top
  top="$(git rev-parse --show-toplevel)"
  printf '%s/../.ship-graph/%s' "$top" "$(basename "$STATE")"
}

verb_dispatch() {
  local task="${REST[0]:-}" prompt="${REST[1]:-}"
  [ -n "$task" ] || { echo "driver-local.sh dispatch: <task> is required" >&2; exit 1; }
  require_state

  local root path branch
  root="$(workspace_root)"
  mkdir -p "$root"
  path="$root/$task"
  branch="ship/$task"

  if [ ! -d "$path" ]; then
    git worktree add -q "$path" -b "$branch" "${BASE:-HEAD}"
  fi
  path="$(cd "$path" && pwd)"

  {
    printf 'worktree=%s\n' "$path"
    printf 'branch=%s\n' "$branch"
  } > "$STATE/driver-local-$task.txt"
  printf '%s\n' "$task" >> "$STATE/driver-local-dispatched.txt"

  printf 'ok=1\n'
  printf 'worktree=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
  printf 'instruction=Launch one Agent (subagent_type=general-purpose, model sonnet) whose prompt is: "cd %s and run %s to completion. Report its final state= line."\n' \
    "$path" "${prompt:-/ship:run $task}"
}

verb_collect() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-local.sh collect: <task> is required" >&2; exit 1; }
  require_state
  local f="$STATE/driver-local-$task.txt"
  [ -f "$f" ] || { echo "driver-local.sh collect: $task was never dispatched" >&2; exit 1; }
  cat "$f"
  printf 'base=%s\n' "$BASE"
}

verb_wait() {
  require_state
  local list="$STATE/driver-local-dispatched.txt" t
  if [ -s "$list" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf 'done=%s\n' "$t"
    done < <(sort -u "$list")
    : > "$list"
  fi
  printf 'signal=synchronous\n'
  printf 'note=Agents return inside the dispatching turn; every task above has already finished.\n'
}

verb_ask() {
  local question="${REST[0]:-}"
  [ -n "$question" ] || { echo "driver-local.sh ask: <question> is required" >&2; exit 1; }
  printf 'question=%s\n' "$question"
  [ -n "$TASK" ] && printf 'task=%s\n' "$TASK"
  return 0
}

# Agents run inside the orchestrator's own turn, so by the time anything could
# call stop they have already returned — there is no process to signal. The
# workspace is left in place deliberately: it holds the node's work.
verb_stop() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-local.sh stop: <task> is required" >&2; exit 1; }
  printf 'stopped=%s\n' "$task"
  printf 'note=Agents are synchronous here; nothing outlives the turn. Workspace kept.\n'
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

VERB="$1"
shift
parse_flags "$@"

case "$VERB" in
  dispatch) verb_dispatch ;;
  collect)  verb_collect ;;
  wait)     verb_wait ;;
  ask)      verb_ask ;;
  stop)     verb_stop ;;
  *)        usage; exit 1 ;;
esac
