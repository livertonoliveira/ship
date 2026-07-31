#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# driver-orca.sh — Orca as the workspace runtime.
#
# Shaped by what was measured against the live CLI, not by its help text.
#
# The original driver was written against the orchestration API that Orca has
# since RETIRED (`coordinator-start`), and died on its very first call: without a
# Run to hang off, `task-create` falls back to looking up a retained legacy
# coordinator, cannot prove that coordinator's original process identity, and
# answers `legacy_read_only`. No workspace was ever created, so the graph could
# not even fall back to inspecting one. Measured 2026-07-30: this fails from an
# Orca-native pane too, so it was never about who was calling.
#
# The modern shape, all four verified from a plain subprocess:
#   1. `orchestration run-create --objective <o>` binds this terminal as the
#      Run's coordinator (legacy: 0). EVERY later call carries `--run`; that is
#      the whole difference between working and legacy_read_only.
#   2. `orchestration worker-start --task <t> --run <r> --agent claude` creates
#      the Orca-managed worktree, launches the agent, registers the dispatch and
#      delivers the lifecycle preamble + TASK block as accepted input — one call
#      replacing the four this driver used to make, and removing the paste-then-
#      press-Enter dance that used to leave workers idle with an unsent brief.
#   3. Because the worktree is created THROUGH Orca, it is registered with the
#      app and shows up in its UI. A plain `git worktree` beside the repo (what
#      driver-local makes) never does.
#   4. `--wait` writes JSON keepalives to stderr every 15s, so stderr must be
#      discarded or it contaminates the caller's parse.
#
# Completion still does not depend on any of this: graph.sh poll observes
# homolog-approved.txt (docs/graph-mode-orca-findings.md §B). worker_done only
# ends the wait window early.
#
# Verbs: dispatch | collect | wait | ask | stop | probe  (contract in driver-manual.sh)
# ---------------------------------------------------------------------------

usage() {
  echo "usage: driver-orca.sh <dispatch|collect|wait|ask|stop|probe> [args...]" >&2
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

# Orca reports a branch as a full ref (refs/heads/x); driver-local reports the
# short name. graph.sh feeds whichever it gets straight into `git merge`, so both
# work — but only one of them reads correctly in a status table, and a driver
# swap must not change the shape of the graph's own state.
short_branch() {
  printf '%s' "${1#refs/heads/}"
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

# A graph only carries an explicit repo when it spans several. For the single-repo
# case `--repo` arrives empty, and worker-start then infers the repo from the
# CALLING terminal — which is the coordinator's checkout, not necessarily the one
# the graph is running over. Resolving it from the working tree instead keeps a
# graph driven from anywhere creating its node workspaces in the right repo.
#
# The git COMMON dir, not the toplevel: inside a worktree the toplevel is the
# worktree's own path and would match no registered repo.
resolve_repo() {
  [ -z "$REPO" ] || return 0
  local common root
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] || return 0
  root="$(dirname "$common")"
  REPO="$(orca repo list --json 2>/dev/null | awk -v want="$root" '
    # Always the LAST id seen before the path, never the first: every response
    # opens with a per-call request-envelope "id", and holding onto that one
    # returns a fresh random uuid for whichever repo happens to be listed first.
    /"id"[[:space:]]*:/ {
      line = $0
      sub(/.*"id"[[:space:]]*:[[:space:]]*"/, "", line); sub(/".*/, "", line); id = line
    }
    /"path"[[:space:]]*:/ {
      line = $0
      sub(/.*"path"[[:space:]]*:[[:space:]]*"/, "", line); sub(/".*/, "", line)
      if (line == want && id != "") { print id; exit }
    }
  ')"
}

kv_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^$key=//p" "$file" | head -1
}

# --- the Run ----------------------------------------------------------------
#
# A Run is the namespace every modern orchestration call hangs off. Without one,
# `task-create` falls back to looking up a retained coordinator from the retired
# `coordinator-start` scheme and answers legacy_read_only — which is what made
# this driver die before it had created anything at all. `run-create` binds the
# calling terminal as coordinator (legacy: 0) and every later call carries
# `--run`, so nothing depends on that retired lookup.
ensure_run() {
  local f="$STATE/driver-orca-run.txt" run

  run="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$run" ]; then
    printf '%s' "$run"
    return 0
  fi

  run="$(orca orchestration run-create --objective "Ship graph: $(basename "$STATE")" --json 2>/dev/null \
    | json_id run_)"
  [ -n "$run" ] || return 1
  printf '%s\n' "$run" > "$f"
  printf '%s' "$run"
}

verb_dispatch() {
  local task="${REST[0]:-}" prompt="${REST[1]:-}"
  [ -n "$task" ] || { echo "driver-orca.sh dispatch: <task> is required" >&2; exit 1; }
  require_state
  require_cli
  resolve_repo
  prompt="${prompt:-/ship:run $task}"

  local run
  run="$(ensure_run)" || {
    echo "driver-orca.sh dispatch: could not create an orchestration Run — the runtime is reachable but refused to bind this terminal as coordinator." >&2
    echo "  Switch runtimes without losing the graph: graph.sh abort, then graph.sh set --driver local" >&2
    exit 1
  }

  local created rtask
  created="$(orca orchestration task-create --spec "$prompt" --task-title "$task" --run "$run" --json 2>/dev/null)"
  rtask="$(printf '%s' "$created" | json_id task_)"
  [ -n "$rtask" ] || { echo "driver-orca.sh dispatch: task-create returned no task id (run $run)" >&2; exit 1; }
  printf '%s\n' "$(printf '%s' "$created" | json_val created_by_terminal_handle)" \
    > "$STATE/driver-orca-coordinator.txt"

  # One call replaces four. `worker-start` creates the Orca-managed worktree,
  # launches the agent in it, registers the dispatch AND delivers the lifecycle
  # preamble + TASK block as accepted input — the last of which is what the old
  # deliver_prompt existed to fake by pasting into the TUI and pressing Enter.
  # Because the worktree is created THROUGH Orca it is registered with the app,
  # so it appears in the UI; a plain `git worktree` beside the repo never does.
  local start_args=(orchestration worker-start --task "$rtask" --run "$run"
                    --name "$task" --display-name "$task" --worktree new-top-level --setup run --json)
  [ -n "$REPO" ] && start_args+=(--repo "id:$REPO")
  [ -n "$BASE" ] && start_args+=(--base-branch "$BASE")

  # `--agent` launches the runtime's default agent command and accepts no extra
  # argv, so a worker resolves whatever Ship is INSTALLED globally rather than
  # the tree under test. SHIP_WORKER_COMMAND builds the terminal itself and hands
  # worker-start the handle, which is also how a non-default model or effort gets
  # in — and how the e2e smoke test measures the build it just compiled.
  # Initialised, not merely declared: since bash 4.4 a bare `local x` leaves x
  # UNSET, and the `[ -n "$wt_id" ]` fallbacks below then abort under `set -u`.
  # macOS ships bash 3.2, where a bare `local` yields an empty string, so this
  # branch worked on the machine it was written on and died everywhere else.
  local wt_id="" term="" handle=""
  if [ -n "${SHIP_WORKER_COMMAND:-}" ]; then
    local wt_args=(worktree create --name "$task" --no-parent --setup run --json)
    [ -n "$REPO" ] && wt_args+=(--repo "id:$REPO")
    [ -n "$BASE" ] && wt_args+=(--base-branch "$BASE")
    local wt
    wt="$(orca "${wt_args[@]}" 2>/dev/null)"
    wt_id="$(printf '%s' "$wt" | grep -oE '"[^"]+::[^"]+"' | head -1 | tr -d '"')"
    [ -n "$wt_id" ] || { echo "driver-orca.sh dispatch: no worktree id in the create response" >&2; exit 1; }
    term="$(orca terminal create --worktree "id:$wt_id" --title "$task" --command "$SHIP_WORKER_COMMAND" --json 2>/dev/null)"
    handle="$(printf '%s' "$term" | json_id term_)"
    [ -n "$handle" ] || { echo "driver-orca.sh dispatch: terminal create returned no handle" >&2; exit 1; }
    orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms 120000 >/dev/null 2>&1 || true
    start_args+=(--terminal "$handle" --worktree "id:$wt_id")
  else
    start_args+=(--agent claude)
  fi

  local started dispatch_id
  started="$(orca "${start_args[@]}" 2>/dev/null)"
  dispatch_id="$(printf '%s' "$started" | json_id ctx_)"
  [ -n "$dispatch_id" ] || { echo "driver-orca.sh dispatch: worker-start returned no dispatch id" >&2; exit 1; }

  # worker-start reports what it created under result.effects; the worktree id is
  # the only <repo-id>::<path> value in the response.
  [ -n "$wt_id" ] || wt_id="$(printf '%s' "$started" | grep -oE '"[^"]+::[^"]+"' | head -1 | tr -d '"')"
  [ -n "$handle" ] || handle="$(printf '%s' "$started" | json_id term_)"

  local shown path branch
  shown="$(orca worktree show --worktree "id:$wt_id" --json 2>/dev/null)"
  path="$(printf '%s' "$shown" | json_val path)"
  branch="$(short_branch "$(printf '%s' "$shown" | json_val branch)")"

  {
    printf 'run=%s\n' "$run"
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
  printf 'dispatch=%s\n' "$dispatch_id"
  printf 'note=Worker started and its brief accepted by the runtime; the workspace is Orca-managed and visible in the app.\n'
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
  printf 'branch=%s\n' "$(short_branch "$(printf '%s' "$shown" | json_val branch)")"
  printf 'base=%s\n' "$(printf '%s' "$shown" | json_val baseRef)"
}

# `done=` is deliberately NOT emitted. A worker_done message is a hint that a
# worker thinks it finished; graph.sh poll decides it, by reading the
# workspace's own homolog-approved.txt. The message is still worth waiting on
# because it ends the wait window early — it just does not get to land a node.
verb_wait() {
  require_state
  require_cli

  local run coordinator args=() out
  run="$(cat "$STATE/driver-orca-run.txt" 2>/dev/null || true)"
  coordinator="$(cat "$STATE/driver-orca-coordinator.txt" 2>/dev/null || true)"

  args=(orchestration check --wait --types worker_done,escalation --timeout-ms "$TIMEOUT_MS" --json)
  [ -n "$run" ] && args+=(--run "$run")
  [ -n "$coordinator" ] && args+=(--terminal "$coordinator")

  # stderr carries the 15s keepalives, never results.
  out="$(orca "${args[@]}" 2>/dev/null || true)"

  local payload
  payload="$(printf '%s' "$out" | grep -oE 'task_[0-9a-zA-Z]+' | head -1 || true)"
  if [ -n "$payload" ]; then
    local f rtask task
    for f in "$STATE"/driver-orca-*.txt; do
      [ -f "$f" ] || continue
      rtask="$(kv_get "$f" runtime_task)"
      [ "$rtask" = "$payload" ] || continue
      task="$(basename "$f" .txt)"
      task="${task#driver-orca-}"
      printf 'reported=%s\n' "$task"
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
# Outranks the others when the runtime is actually up, because it is the only one
# whose workers get their own process and whose workspaces the app can show.
#
# The CLI being on PATH is not enough: it answers fine with the app closed, and a
# graph that picked this driver on that basis would fail at the first dispatch.
# So the probe asks the runtime whether it is reachable, and reads only that.
verb_probe() {
  if ! command -v orca >/dev/null 2>&1; then
    printf 'ready=0\n'
    printf 'reason=orca not on PATH\n'
    return 0
  fi
  if orca status --json 2>/dev/null | grep -q '"reachable"[[:space:]]*:[[:space:]]*true'; then
    printf 'ready=1\n'
    printf 'priority=10\n'
    printf 'workspaces=one runtime-managed workspace per node, visible in the app\n'
    printf 'reason=orca runtime reachable; workers get their own terminal and the workspaces show in the app\n'
  else
    printf 'ready=0\n'
    printf 'reason=orca on PATH but its runtime is not reachable\n'
  fi
}

verb_stop() {
  local task="${REST[0]:-}"
  [ -n "$task" ] || { echo "driver-orca.sh stop: <task> is required" >&2; exit 1; }
  require_state
  require_cli

  local f="$STATE/driver-orca-$task.txt" handle wt_id dispatch
  handle="$(kv_get "$f" handle)"
  wt_id="$(kv_get "$f" worktree_id)"
  dispatch="$(kv_get "$f" dispatch)"

  # Fencing the dispatch is what actually stops a SUPERVISED worker: it tells the
  # runtime the worker is done being listened to, so a late message cannot revive
  # it. Closing the pane alone leaves the dispatch live.
  if [ -n "$dispatch" ]; then
    orca orchestration worker-stop --dispatch "$dispatch" --json >/dev/null 2>&1 \
      || orca orchestration worker-abandon --dispatch "$dispatch" --json >/dev/null 2>&1 || true
  fi
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
  probe)    verb_probe ;;
  *)        usage; exit 1 ;;
esac
