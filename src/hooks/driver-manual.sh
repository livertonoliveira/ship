#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# driver-manual.sh — the no-runtime driver. `dispatch` and `wait` print what the
# human has to do; nothing is spawned and nothing is waited on.
#
# It exists for two reasons. It is how you coordinate N workspaces by hand
# without losing track of the frontier, and it is what makes graph.sh testable
# in CI, where no workspace runtime is installed.
#
# Five verbs, same contract in every driver:
#   dispatch <task> <prompt> [--repo <r>] [--state <dir>] [--base <ref>]
#   collect  <task> [--state <dir>]
#   wait     [--state <dir>] [--timeout-ms <n>]
#   ask      <question> [--task <t>] [--state <dir>]
#   stop     <task> [--state <dir>]
#   probe    — can this driver run here, and how strongly does it want the job?
# Output is key=value lines on stdout; graph.sh and the orchestrator read those.
# ---------------------------------------------------------------------------

usage() {
  echo "usage: driver-manual.sh <dispatch|collect|wait|ask|stop|probe> [args...]" >&2
}

STATE=""
REPO=""
BASE=""
TASK=""
TIMEOUT_MS=""

parse_flags() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) STATE="$2"; shift 2 ;;
      --repo) REPO="$2"; shift 2 ;;
      --base) BASE="$2"; shift 2 ;;
      --task) TASK="$2"; shift 2 ;;
      --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) REST+=("$1"); shift ;;
    esac
  done
}

state_file() {
  [ -n "$STATE" ] || return 1
  mkdir -p "$STATE"
  printf '%s/driver-manual-%s.txt' "$STATE" "$1"
}

verb_dispatch() {
  local task="${REST[0]:-}" prompt="${REST[1]:-}"
  [ -n "$task" ] || { echo "driver-manual.sh dispatch: <task> is required" >&2; exit 1; }

  local f
  if f="$(state_file "$task")"; then
    printf 'pending\n' > "$f"
  fi

  printf 'ok=1\n'
  printf 'manual=1\n'
  printf 'instruction=Create a workspace for %s (branch it from %s) and run: %s\n' \
    "$task" "${BASE:-the base branch}" "${prompt:-/ship:run $task}"
  [ -n "$REPO" ] && printf 'repo=%s\n' "$REPO"
  printf 'note=Then re-run collect for %s with the workspace path you created.\n' "$task"
}

# Nothing to resolve: the human made the workspace, so the human supplies the
# path. Printing empty values keeps the key=value contract intact — the
# orchestrator asks the user rather than reading a runtime.
verb_collect() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-manual.sh collect: <task> is required" >&2; exit 1; }
  printf 'worktree=\n'
  printf 'branch=\n'
  printf 'base=%s\n' "$BASE"
  printf 'manual=1\n'
  printf 'note=Ask the user for the workspace path and branch of %s, then pass them to graph.sh claim.\n' "$task"
}

verb_wait() {
  printf 'timeout=1\n'
  printf 'manual=1\n'
  printf 'note=No runtime to wait on. Ask the user which tasks have finished, then land each one.\n'
}

verb_ask() {
  local question="${REST[0]:-}"
  [ -n "$question" ] || { echo "driver-manual.sh ask: <question> is required" >&2; exit 1; }
  printf 'question=%s\n' "$question"
  [ -n "$TASK" ] && printf 'task=%s\n' "$TASK"
  printf 'manual=1\n'
}

# Always available and always last: it needs nothing, and it costs a human a
# workspace per node. Anything that can actually spawn one should outrank it.
verb_probe() {
  printf 'ready=1\n'
  printf 'priority=90\n'
  printf 'reason=no runtime needed; every workspace is created by hand\n'
}

verb_stop() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-manual.sh stop: <task> is required" >&2; exit 1; }
  printf 'stopped=%s\n' "$task"
  printf 'manual=1\n'
  printf 'note=Nothing was spawned, so nothing to stop. Close the workspace you opened for %s yourself.\n' "$task"
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
  probe)    verb_probe ;;
  *)        usage; exit 1 ;;
esac
