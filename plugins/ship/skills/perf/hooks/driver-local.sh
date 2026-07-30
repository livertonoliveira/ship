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

# `git worktree add` has three failure shapes that all mean "resume", and the
# original `[ ! -d "$path" ] && git worktree add -b` handled none of them:
#
#   * the directory survives but is no longer a worktree (a --fresh, a `worktree
#     remove` that left the dir, a half-finished create) — the old guard saw a
#     directory, skipped creation and reported ok=1 for a path that is not a repo
#     at all, sending the worker to a broken cwd;
#   * the branch outlives its workspace — `add -b` dies with "a branch named ...
#     already exists", exit 255, and the graph loop stops on the non-zero exit;
#   * the branch is checked out in a worktree somewhere else — reuse that one
#     rather than failing.
#
# Every one of these is the normal shape of retrying a node, so none may be fatal.
worktree_for_branch() {
  git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$1" '
    /^worktree /  { p = substr($0, 10) }
    $0 == "branch " b { print p; exit }'
}

ensure_worktree() {
  local path="$1" branch="$2" existing

  # Registrations pointing at deleted directories otherwise make both the
  # "is it a worktree" and the "add" paths lie.
  git worktree prune >/dev/null 2>&1 || true

  existing="$(worktree_for_branch "$branch")"
  if [ -n "$existing" ] && [ -d "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi

  if [ -d "$path" ]; then
    if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf '%s' "$path"
      return 0
    fi
    if [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
      echo "driver-local.sh dispatch: $path exists and is not a git worktree — remove it before retrying this node" >&2
      return 1
    fi
    rmdir "$path" 2>/dev/null || true
  fi

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add -q "$path" "$branch" || return 1
  else
    git worktree add -q "$path" -b "$branch" "${BASE:-HEAD}" || return 1
  fi
  printf '%s' "$path"
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

  path="$(ensure_worktree "$path" "$branch")" || exit 1
  path="$(cd "$path" && pwd)"

  {
    printf 'worktree=%s\n' "$path"
    printf 'branch=%s\n' "$branch"
  } > "$STATE/driver-local-$task.txt"
  printf '%s\n' "$task" >> "$STATE/driver-local-dispatched.txt"

  printf 'ok=1\n'
  printf 'worktree=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
  # This driver prepares the workspace; it cannot start the worker, because the
  # worker is an Agent only the caller can launch. Saying so explicitly matters:
  # a caller that runs dispatch/collect/claim and skips this line leaves a node
  # claimed in_flight with an empty workspace and nothing running in it.
  printf 'instruction=REQUIRED — the workspace is ready but NOTHING is running in it yet. Launch one Agent (subagent_type=general-purpose, model sonnet) with the prompt: "cd %s and run %s to completion. Report its final state= line." Launch it now and let it finish in this turn; this driver has no background worker and nothing else will start one.\n' \
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

# `returned=`, never `done=`. The Agent handing control back says only that the
# turn ended — not that the pipeline reached its end, and certainly not that the
# node may be landed. graph.sh poll decides that, by reading the workspace's own
# homolog-approved.txt. Emitting `done=` here read as a completion signal the
# driver has no standing to give, and it survived a --fresh: the leftover
# dispatch list made the first wait of a brand-new graph report tasks it had
# never dispatched.
verb_wait() {
  require_state
  local list="$STATE/driver-local-dispatched.txt" t
  if [ -s "$list" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      # Only tasks this driver still holds state for. Anything else is debris
      # from a previous run and must not be reported as activity.
      [ -f "$STATE/driver-local-$t.txt" ] || continue
      printf 'returned=%s\n' "$t"
    done < <(sort -u "$list")
    : > "$list"
  fi
  printf 'signal=synchronous\n'
  printf 'note=Agents run inside the dispatching turn, so there is nothing to block on here. Whether a node FINISHED is graph.sh poll'"'"'s call, not this one'"'"'s.\n'
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
