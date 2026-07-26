#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# driver-orca.sh — Orca as the workspace runtime.
#
# Shaped by what Phase 0 actually measured (docs/graph-mode-orca-findings.md),
# not by the CLI's help text. Two things there differ from the original design:
#
#   1. `dispatch` is four calls, not one. `worktree create --prompt` starts a
#      worker but creates no orchestration provenance, and `dispatch --inject`
#      pastes the brief without submitting it. So: create the task, create the
#      workspace, register the dispatch, then deliver the preamble and Enter in a
#      single `terminal send`.
#   2. `--wait` writes JSON keepalives to stderr every 15s, so stderr must be
#      discarded or it contaminates the caller's parse.
#
# Verbs: dispatch | collect | wait | ask | stop  (contract in driver-manual.sh)
# ---------------------------------------------------------------------------

usage() {
  echo "usage: driver-orca.sh <dispatch|collect|wait|ask|stop> [args...]" >&2
}

STATE=""
REPO=""
BASE=""
TASK=""
TIMEOUT_MS="300000"

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

require_state() {
  [ -n "$STATE" ] || { echo "driver-orca.sh: --state <dir> is required" >&2; exit 1; }
  mkdir -p "$STATE"
}

require_cli() {
  command -v orca >/dev/null 2>&1 || {
    echo "driver-orca.sh: 'orca' not found on PATH — switch the graph to driver=local or driver=manual" >&2
    exit 1
  }
}

# The responses are machine-generated and pretty-printed one key per line, so a
# line-oriented match is enough here; graph.sh's real parser stays in graph.sh.
json_val() {
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Every response opens with a request-envelope "id", so matching the key alone
# would return that instead of the record's own id. Match the value's shape.
json_id() {
  grep -oE "\"$1[0-9a-zA-Z_-]+\"" | head -1 | tr -d '"'
}

kv_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^$key=//p" "$file" | head -1
}

# Delivering a brief to an agent TUI takes two writes, not one, and the second
# must be observed rather than timed.
#
# Measured against live worktrees, three times:
#   * `dispatch --inject` pastes the brief and never submits it.
#   * `terminal send --text "<multi-line>" --enter` also never submits: the
#     trailing newline is consumed as part of the paste, not as a keystroke.
#   * `terminal send --text "" --enter` as a SEPARATE call does submit.
#
# So: paste, wait until the text is actually visible in the buffer, then send a
# bare Enter. Waiting on the buffer rather than on a sleep is the whole point —
# an earlier "fix" sent the Enter immediately, it landed mid-paste and was
# swallowed, and it only ever looked correct in probes where minutes happened to
# have passed.
deliver_prompt() {
  local handle="$1" text="$2" marker attempt=0 tries

  # The brief's last line is the task prompt itself — short and distinctive.
  marker="$(printf '%s' "$text" | sed -e '/^[[:space:]]*$/d' | tail -1 | cut -c1-30)"

  # 1. Wait for the agent TUI to be accepting input. `terminal wait --for
  #    tui-idle` answers satisfied=true immediately and gates nothing, so read
  #    the pane instead: the footer only renders once the TUI is up. Sending
  #    before that drops the whole brief into a terminal that is still booting.
  tries=0
  while [ "$tries" -lt 45 ]; do
    orca terminal read --terminal "$handle" 2>/dev/null | grep -qE 'bypass permissions|Claude Code|❯' && break
    tries=$((tries + 1))
    sleep 2
  done

  # 2. Send, then confirm it actually landed, then submit — and re-send if it
  #    did not. An earlier version sent once, waited, and proceeded regardless;
  #    when the send was lost it pressed Enter on an empty prompt and reported
  #    success, leaving the node idle for half an hour.
  while [ "$attempt" -lt 4 ]; do
    attempt=$((attempt + 1))
    orca terminal send --terminal "$handle" --text "$text" >/dev/null 2>&1 || true

    tries=0
    while [ "$tries" -lt 15 ]; do
      if [ -z "$marker" ] || orca terminal read --terminal "$handle" 2>/dev/null | grep -qF "$marker"; then
        # A multi-line paste never submits itself: the trailing newline of
        # `--enter` is consumed as part of the paste. The submit has to be its
        # own keystroke, after the paste is visible.
        orca terminal send --terminal "$handle" --text "" --enter >/dev/null 2>&1 || true
        return 0
      fi
      tries=$((tries + 1))
      sleep 2
    done
  done

  echo "driver-orca.sh: brief never landed in $handle after $attempt attempts" >&2
  return 1
}

verb_dispatch() {
  local task="${REST[0]:-}" prompt="${REST[1]:-}"
  [ -n "$task" ] || { echo "driver-orca.sh dispatch: <task> is required" >&2; exit 1; }
  require_state
  require_cli
  prompt="${prompt:-/ship:run $task}"

  local created rtask coordinator
  created="$(orca orchestration task-create --spec "$prompt" --task-title "$task" --json 2>/dev/null)"
  rtask="$(printf '%s' "$created" | json_id task_)"
  [ -n "$rtask" ] || { echo "driver-orca.sh dispatch: task-create returned no task id" >&2; exit 1; }
  coordinator="$(printf '%s' "$created" | json_val created_by_terminal_handle)"
  [ -n "$coordinator" ] && printf '%s\n' "$coordinator" > "$STATE/driver-orca-coordinator.txt"

  local create_args=(worktree create --name "$task" --no-parent --setup run --json)
  [ -n "$REPO" ] && create_args+=(--repo "id:$REPO")
  [ -n "$BASE" ] && create_args+=(--base-branch "$BASE")
  # `worktree create --agent` launches the runtime's default agent command and
  # accepts no extra argv, so a worker always resolves whatever Ship is INSTALLED
  # globally — never the tree under test. SHIP_WORKER_COMMAND takes the two-step
  # path instead (create the workspace, then the terminal with an explicit
  # command), which is also how a non-default model or effort gets in.
  [ -z "${SHIP_WORKER_COMMAND:-}" ] && create_args+=(--agent claude)

  local wt handle wt_id branch path
  wt="$(orca "${create_args[@]}" 2>/dev/null)"
  wt_id="$(printf '%s' "$wt" | grep -oE '"[^"]+::[^"]+"' | head -1 | tr -d '"')"
  path="$(printf '%s' "$wt" | json_val path)"
  branch="$(printf '%s' "$wt" | json_val branch)"

  if [ -n "${SHIP_WORKER_COMMAND:-}" ]; then
    [ -n "$wt_id" ] || { echo "driver-orca.sh dispatch: no worktree id in the create response" >&2; exit 1; }
    local term
    term="$(orca terminal create --worktree "id:$wt_id" --title "$task" --command "$SHIP_WORKER_COMMAND" --json 2>/dev/null)"
    handle="$(printf '%s' "$term" | json_id term_)"
    orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms 120000 >/dev/null 2>&1 || true
  else
    # Newer runtimes surface result.agentTerminalHandle; the one Phase 0 ran
    # against returned only result.startupTerminal.handle.
    handle="$(printf '%s' "$wt" | json_val agentTerminalHandle)"
    [ -n "$handle" ] || handle="$(printf '%s' "$wt" | json_id term_)"
  fi
  [ -n "$handle" ] || { echo "driver-orca.sh dispatch: no agent terminal handle in the create response" >&2; exit 1; }

  # Deliberately NOT --inject. Measured twice against live worktrees: --inject
  # pastes the preamble + TASK block into the agent's prompt without submitting
  # it, and the worker then sits idle forever with its whole brief unsent. A
  # follow-up Enter only appears to fix it — inject delivers asynchronously, so
  # an immediate Enter lands mid-paste and is swallowed. It worked in manual
  # probes purely because minutes had passed.
  #
  # Instead: register the dispatch for tracking, read the same preamble back as
  # plain text, and deliver text + Enter in ONE terminal send. Atomic, so there
  # is no window to race.
  local dispatched dispatch_id preamble
  dispatched="$(orca orchestration dispatch --task "$rtask" --to "$handle" --json 2>/dev/null)"
  dispatch_id="$(printf '%s' "$dispatched" | json_id ctx_)"

  preamble="$(orca orchestration dispatch-show --task "$rtask" --preamble 2>/dev/null)"
  deliver_prompt "$handle" "${preamble:-$prompt}"

  {
    printf 'runtime_task=%s\n' "$rtask"
    printf 'dispatch=%s\n' "$dispatch_id"
    printf 'handle=%s\n' "$handle"
    printf 'worktree_id=%s\n' "$wt_id"
    printf 'worktree=%s\n' "$path"
    printf 'branch=%s\n' "$branch"
  } > "$STATE/driver-orca-$task.txt"

  printf 'ok=1\n'
  printf 'handle=%s\n' "$handle"
  printf 'worktree=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
  printf 'runtime_task=%s\n' "$rtask"
}

verb_collect() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-orca.sh collect: <task> is required" >&2; exit 1; }
  require_state
  require_cli

  local f="$STATE/driver-orca-$task.txt" wt_id shown
  [ -f "$f" ] || { echo "driver-orca.sh collect: $task was never dispatched" >&2; exit 1; }
  wt_id="$(kv_get "$f" worktree_id)"
  [ -n "$wt_id" ] || { echo "driver-orca.sh collect: no worktree id recorded for $task" >&2; exit 1; }

  shown="$(orca worktree show --worktree "id:$wt_id" --json 2>/dev/null)"
  printf 'worktree=%s\n' "$(printf '%s' "$shown" | json_val path)"
  printf 'branch=%s\n' "$(printf '%s' "$shown" | json_val branch)"
  printf 'base=%s\n' "$(printf '%s' "$shown" | json_val baseRef)"
}

verb_wait() {
  require_state
  require_cli

  local coordinator args=() out payload rtask f task
  coordinator="$(cat "$STATE/driver-orca-coordinator.txt" 2>/dev/null || true)"
  args=(orchestration check --wait --types worker_done,escalation --timeout-ms "$TIMEOUT_MS" --json)
  [ -n "$coordinator" ] && args=(orchestration check --terminal "$coordinator" --wait --types worker_done,escalation --timeout-ms "$TIMEOUT_MS" --json)

  # stderr carries the 15s keepalives, never results.
  out="$(orca "${args[@]}" 2>/dev/null || true)"

  payload="$(printf '%s' "$out" | grep -oE 'task_[0-9a-zA-Z]+' | head -1 || true)"
  if [ -n "$payload" ]; then
    for f in "$STATE"/driver-orca-*.txt; do
      [ -f "$f" ] || continue
      rtask="$(kv_get "$f" runtime_task)"
      [ "$rtask" = "$payload" ] || continue
      task="$(basename "$f" .txt)"
      task="${task#driver-orca-}"
      printf 'done=%s\n' "$task"
    done
  fi

  if printf '%s' "$out" | grep -q '"type"[[:space:]]*:[[:space:]]*"escalation"'; then
    printf 'signal=escalation\n'
  elif [ -n "$payload" ]; then
    printf 'signal=worker_done\n'
  else
    # A timeout is a checkpoint, not a failure: coding tasks routinely run long.
    printf 'timeout=1\n'
  fi
}

verb_ask() {
  local question="${REST[0]:-}"
  [ -n "$question" ] || { echo "driver-orca.sh ask: <question> is required" >&2; exit 1; }
  require_cli

  local rtask="" gate
  if [ -n "$TASK" ] && [ -n "$STATE" ]; then
    rtask="$(kv_get "$STATE/driver-orca-$TASK.txt" runtime_task)"
  fi

  # A gate needs a task to hang off. Graph-level questions (dependency deadlock,
  # merge-fix cap) belong to no task, so they go back to the user in context.
  if [ -n "$rtask" ]; then
    gate="$(orca orchestration gate-create --task "$rtask" --question "$question" --json 2>/dev/null | json_id gate_)"
    if [ -n "$gate" ]; then
      printf 'gate=%s\n' "$gate"
      printf 'task=%s\n' "$TASK"
      return 0
    fi
  fi
  printf 'question=%s\n' "$question"
  [ -n "$TASK" ] && printf 'task=%s\n' "$TASK"
  return 0
}

# Closes the worker's terminal and leaves the workspace on disk. A killed
# orchestrator cannot signal anything — traps do not run on SIGKILL — so without
# this an abandoned run leaves agents working and billing indefinitely, invisible
# in `worktree list` once the repo is de-registered.
#
# The workspace is deliberately NOT removed: a stopped node's work is what you
# inspect to decide whether to retry or drop it.
verb_stop() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-orca.sh stop: <task> is required" >&2; exit 1; }
  require_state
  require_cli

  local f="$STATE/driver-orca-$task.txt" handle wt_id
  handle="$(kv_get "$f" handle)"
  wt_id="$(kv_get "$f" worktree_id)"

  if [ -n "$handle" ]; then
    orca terminal close --terminal "$handle" >/dev/null 2>&1 || true
  fi
  # Handles can change when a pane restarts, so sweep the workspace too rather
  # than trusting the one recorded at dispatch.
  if [ -n "$wt_id" ]; then
    orca terminal stop --worktree "id:$wt_id" >/dev/null 2>&1 || true
  fi

  printf 'stopped=%s\n' "$task"
  [ -n "$handle" ] && printf 'handle=%s\n' "$handle"
  printf 'note=Workspace kept for inspection; only the agent was stopped.\n'
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
