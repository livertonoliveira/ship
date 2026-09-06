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
#      is DOCUMENTED to deliver the lifecycle preamble + TASK block as accepted
#      input — one call replacing four. Measured 2026-07-30 across five workers
#      started in one burst: it delivered all five briefs and submitted none of
#      them. Every worker sat idle at its prompt with the whole brief pasted and
#      unsent. So the delivery is a claim, never a guarantee, and dispatch does
#      not get to believe it — see confirm_working below.
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
# Verbs: dispatch | collect | wait | ask | resume | stop | probe  (contract in driver-manual.sh)
# ---------------------------------------------------------------------------

usage() {
  echo "usage: driver-orca.sh <dispatch|collect|wait|ask|resume|stop|probe> [args...]" >&2
}

STATE=""
REPO=""
BASE=""
TASK=""
TIMEOUT_MS="300000"
UNTIL_FILES=""

parse_flags() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) STATE="$2"; shift 2 ;;
      --repo) REPO="$2"; shift 2 ;;
      --base) BASE="$2"; shift 2 ;;
      --task) TASK="$2"; shift 2 ;;
      --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
      --until-file) UNTIL_FILES="$UNTIL_FILES$2
"; shift 2 ;;
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

# One repo of the runtime's, by whatever name the caller had for it.
#
# `repo list` answers with an id, a path and a displayName per repo. The graph's
# nodes.json carries whichever of those the coordinator could get: SKILL.md
# step 2 says `repo` is the `repo:<name>` Linear label, and that label holds a
# display name — while worker-start's selector only accepts the id. So a project
# whose issues carry a repo: label built a graph that could not dispatch a single
# node, and the only sign of it was an exit code. Matching all three closes that
# gap: the label works, the id works, a path works.
repo_id_for() {
  orca repo list --json 2>/dev/null | awk -v want="$1" '
    # One field per line, so a record is accumulated and matched at its closing
    # brace — the key order in the response is not part of this contract.
    # The envelope opens with its own request "id", which the first repo record
    # overwrites before any brace closes.
    /"id"[[:space:]]*:/          { v=$0; sub(/.*"id"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); id=v }
    /"path"[[:space:]]*:/        { v=$0; sub(/.*"path"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); path=v }
    /"displayName"[[:space:]]*:/ { v=$0; sub(/.*"displayName"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); name=v }
    /}/ {
      if (id != "" && (id == want || path == want || name == want)) { print id; exit }
      path=""; name=""
    }
  '
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
  local want="$REPO" id
  if [ -z "$want" ]; then
    local common
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$common" ] || return 0
    want="$(dirname "$common")"
  fi

  id="$(repo_id_for "$want" || true)"
  if [ -n "$id" ]; then
    REPO="$id"
    return 0
  fi

  # Inferred from the working tree and matching nothing is not an error: the
  # graph may be driven from outside any registered repo, and worker-start still
  # has the calling terminal to fall back on.
  [ -n "$REPO" ] || return 0

  # An explicit value that resolves to nothing is a graph that cannot dispatch a
  # single node, and saying so here costs one call — against a whole run spent
  # discovering it a workspace at a time.
  {
    echo "driver-orca.sh: --repo '$REPO' matches no repo registered with the runtime"
    echo "  give its id, its path, or its display name. Known now:"
    orca repo list --json 2>/dev/null \
      | sed -n 's/.*"displayName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/    \1/p'
  } >&2
  exit 1
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
#
# Creating it is serialized with an atomic mkdir lock, because a graph dispatches
# its whole frontier at once. Measured live with two concurrent dispatches: both
# found no Run, both created one, and the second's task-create came back
# `consumer_fenced: this coordinator terminal is bound to run_X, not run_Y` —
# the terminal binds to exactly one Run, so every node after the first never
# started. A read-then-write with no lock loses that race every time.
ensure_run() {
  local f="$STATE/driver-orca-run.txt" lock="$STATE/driver-orca-run.lock" run tries=0

  run="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$run" ]; then
    printf '%s' "$run"
    return 0
  fi

  while ! mkdir "$lock" 2>/dev/null; do
    run="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$run" ]; then
      printf '%s' "$run"
      return 0
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 120 ] && break
    sleep 1
  done

  # Re-read inside the lock: the holder we queued behind is what created it.
  run="$(cat "$f" 2>/dev/null || true)"
  if [ -z "$run" ]; then
    run="$(orca orchestration run-create --objective "Ship graph: $(basename "$STATE")" --json 2>/dev/null \
      | json_id run_)"
    [ -n "$run" ] && printf '%s\n' "$run" > "$f"
  fi
  rmdir "$lock" 2>/dev/null || true

  [ -n "$run" ] || return 1
  printf '%s' "$run"
}

# --- proving the worker is actually working ---------------------------------
#
# No dispatch may report ok=1 on a runtime's promise. The only acceptable
# evidence is the worker's own pane moving.
#
# Measured live against two panes, one working and one holding an unsent brief:
# an agent TUI that is processing redraws its status line every second, so a tail
# read twice a few seconds apart HASHES DIFFERENTLY (1482124910 → 2576027581).
# One idle at its prompt hashes identically (1653924144 → 1653924144). That is
# the whole detector: no spinner word, no locale, no runtime version in it.
BUSY_SAMPLE_S="${SHIP_ORCA_BUSY_SAMPLE_S:-4}"

read_tail() {
  orca terminal read --terminal "$1" --limit 40 2>/dev/null || true
}

terminal_working() {
  local a b
  a="$(read_tail "$1" | cksum)"
  sleep "$BUSY_SAMPLE_S"
  b="$(read_tail "$1" | cksum)"
  [ "$a" != "$b" ]
}

# Text sitting in the INPUT BOX is the signature of a delivered-but-unsubmitted
# brief. Only the box counts, and it is the region between the last two rules at
# the bottom of the pane — a submitted brief is still echoed in the scrollback
# above, so matching the whole tail would read every started worker as stuck.
#
# Activity alone is not proof either, which is why this gate exists: measured
# live, a pane still receiving a long paste redraws on every chunk, so the tail
# changes while nothing has been submitted at all.
prompt_holds_text() {
  read_tail "$1" | awk '
    { line[NR] = $0; if ($0 ~ /^[[:space:]]*─────/) { prev = last; last = NR } }
    END {
      if (!last || !prev) exit 1
      for (i = prev + 1; i < last; i++) {
        s = line[i]
        sub(/^[[:space:]]*/, "", s); sub(/^[❯>][[:space:]]*/, "", s)
        gsub(/[[:space:]]/, "", s)
        if (length(s) > 0) exit 0
      }
      exit 1
    }'
}

# Returns only once the pane is observed working. Both failure modes are
# repaired here, and they need different repairs: a brief that arrived but was
# never submitted needs a bare Enter, and one that never arrived needs pasting
# first. A multi-line paste never submits itself — the trailing newline of
# `--enter` is consumed as part of the paste — so the submit is always its own
# keystroke, after the text is visible.
# How many times this dispatch had to repair a delivery the runtime reported as
# accepted. Reported back so a graph run shows how often the promise was empty
# instead of hiding it.
REPAIRS=0

confirm_working() {
  local handle="$1" text="$2" attempt=0 tries=0

  # Sending before the TUI is up drops the brief into a booting terminal.
  while [ "$tries" -lt 45 ]; do
    read_tail "$handle" | grep -qE 'bypass permissions|Claude Code|❯' && break
    tries=$((tries + 1))
    sleep 2
  done

  # An unsent brief is checked BEFORE activity, never after: a pane taking a long
  # paste is busy redrawing and would otherwise pass as working with the whole
  # brief still sitting unsubmitted — measured, and exactly the bug being fixed.
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    if ! prompt_holds_text "$handle" && terminal_working "$handle"; then
      return 0
    fi
    REPAIRS=$((REPAIRS + 1))
    if prompt_holds_text "$handle"; then
      orca terminal send --terminal "$handle" --text "" --enter >/dev/null 2>&1 || true
    else
      orca terminal send --terminal "$handle" --text "$text" >/dev/null 2>&1 || true
      sleep "$BUSY_SAMPLE_S"
      orca terminal send --terminal "$handle" --text "" --enter >/dev/null 2>&1 || true
    fi
    sleep "$BUSY_SAMPLE_S"
  done

  ! prompt_holds_text "$handle" && terminal_working "$handle"
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

  # The worker's own completion call needs the Run, and its preamble does not
  # carry one. Measured 2026-07-30 from a live worker handle:
  #   send --type worker_done            → legacy_read_only, "this retained legacy
  #                                        coordinator could not prove its original
  #                                        process identity. No effects applied."
  #   send --type worker_done --run <r>  → accepted.
  # Workers were burning turns retrying a call that could never succeed. The Run
  # id only exists here, so this is the only place that can hand it over.
  #
  # The runtime's own preamble tells the worker to raise every question through
  # `orchestration ask`, which blocks on a reply the coordinator never reads: the
  # graph's wait window listens for worker_done and escalation only, and every
  # decision the pipeline needs travels through the scratch dir (ask.md /
  # answer.txt, delivered by `resume`). Measured live: three nodes each spent
  # 10-minute timeouts re-asking a channel nobody answered while their answer
  # sat on disk. The spec is the one place this driver can override that rule.
  local spec
  spec="$prompt

When you report completion, your orchestration send MUST carry --run $run in addition to the --dispatch-capability from your preamble. Without --run the runtime resolves a retained legacy coordinator and rejects the message with legacy_read_only.

Questions and decisions: NEVER call \`orca orchestration ask\` and NEVER use AskUserQuestion. pipeline.sh next posts any question it needs answered to .context/ship-run/$task/ask.md and tells you how to wait for the answer; do exactly what it prints and nothing else."

  local created rtask
  created="$(orca orchestration task-create --spec "$spec" --task-title "$task" --run "$run" --json 2>/dev/null || true)"
  rtask="$(printf '%s' "$created" | json_id task_ || true)"
  if [ -z "$rtask" ]; then
    echo "driver-orca.sh dispatch: the runtime refused to create a task for $task on run $run" >&2
    # Its own words beat a generic "no task id": `consumer_fenced` names a Run
    # collision, and that reads nothing like a parse failure.
    printf '%s' "$created" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  runtime said: \1/p' | head -1 >&2
    exit 1
  fi
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
    wt="$(orca "${wt_args[@]}" 2>/dev/null || true)"
    wt_id="$(printf '%s' "$wt" | grep -oE '"[^"]+::[^"]+"' | head -1 | tr -d '"' || true)"
    [ -n "$wt_id" ] || { echo "driver-orca.sh dispatch: no worktree id in the create response" >&2; exit 1; }
    term="$(orca terminal create --worktree "id:$wt_id" --title "$task" --command "$SHIP_WORKER_COMMAND" --json 2>/dev/null || true)"
    handle="$(printf '%s' "$term" | json_id term_ || true)"
    [ -n "$handle" ] || { echo "driver-orca.sh dispatch: terminal create returned no handle" >&2; exit 1; }
    orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms 120000 >/dev/null 2>&1 || true
    start_args+=(--terminal "$handle" --worktree "id:$wt_id")
  else
    start_args+=(--agent claude)
  fi

  local started dispatch_id rc=0
  started="$(orca "${start_args[@]}" 2>/dev/null)" || rc=$?

  # The rc check comes BEFORE any parse of the response, and every parse below
  # ends in `|| true`. Both matter, and the reason is the failure this ordering
  # was written after: a worker-start that dies hard answers with an empty body,
  # `json_id` is a pipeline whose grep then matches nothing, and under
  # `set -o pipefail` a BARE assignment from that pipeline fails — so `set -e`
  # killed the driver with nothing on either stream, three lines above the block
  # written to report exactly this. Measured live: three dispatch attempts, one
  # of them with 2>&1 and an explicit echo of $?, produced `EXIT:1` and not one
  # word about the repo the runtime could not resolve.
  #
  # A FAILED worker-start may still answer with a dispatch id, so the id alone
  # proves nothing either: it exits non-zero and names the stage it died in;
  # measured, a bad --base-branch dies in worktree_create with everything else
  # looking normal.
  if [ "$rc" -ne 0 ] || printf '%s' "$started" | grep -q '"failedStage"'; then
    echo "driver-orca.sh dispatch: the runtime refused to start $task" >&2
    printf '%s' "$started" | sed -n 's/.*"lastError"[[:space:]]*:[[:space:]]*"\(.*\)".*/  runtime said: \1/p' | head -1 >&2
    printf '%s' "$started" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  runtime said: \1/p' | head -1 >&2
    printf '%s' "$started" | sed -n 's/.*"failedStage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  it died in stage: \1/p' | head -1 >&2
    printf '%s' "$started" | grep -q . || echo "  the call answered nothing at all — rerun it without 2>/dev/null to see the runtime's own error" >&2
    exit 1
  fi
  dispatch_id="$(printf '%s' "$started" | json_id ctx_ || true)"
  [ -n "$dispatch_id" ] || { echo "driver-orca.sh dispatch: worker-start returned no dispatch id" >&2; exit 1; }

  # worker-start reports what it created under result.effects; the worktree id is
  # the only <repo-id>::<path> value in the response.
  [ -n "$wt_id" ] || wt_id="$(printf '%s' "$started" | grep -oE '"[^"]+::[^"]+"' | head -1 | tr -d '"' || true)"
  [ -n "$handle" ] || handle="$(printf '%s' "$started" | json_id term_ || true)"
  # Named explicitly, because the alternative is what actually happened: an empty
  # selector makes the next call fail, and a failing command substitution under
  # `set -e` exits the driver with no output on either stream at all.
  [ -n "$wt_id" ] || { echo "driver-orca.sh dispatch: worker-start reported no workspace for $task" >&2; exit 1; }
  [ -n "$handle" ] || { echo "driver-orca.sh dispatch: worker-start reported no agent terminal for $task" >&2; exit 1; }

  # The brief as the runtime built it, so a re-delivery sends the same lifecycle
  # preamble the worker was supposed to get — not a bare prompt line.
  local preamble
  preamble="$(orca orchestration dispatch-show --task "$rtask" --preamble 2>/dev/null || true)"

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

  # The state file is written FIRST so a worker that never starts is still
  # stoppable: an unconfirmed dispatch left the workspace and the agent behind,
  # and a driver that exits without recording them strands both.
  if ! confirm_working "$handle" "${preamble:-$prompt}"; then
    printf 'ok=0\n'
    printf 'handle=%s\n' "$handle"
    printf 'worktree=%s\n' "$path"
    printf 'reason=the worker never started processing its brief — its pane has not moved after four delivery attempts\n'
    echo "driver-orca.sh dispatch: $task was never confirmed working (handle $handle, workspace $path)." >&2
    echo "  Do NOT claim this node. Inspect the pane, then either re-run this dispatch or: driver-orca.sh stop $task --state \"$STATE\"" >&2
    exit 1
  fi

  printf 'ok=1\n'
  printf 'handle=%s\n' "$handle"
  printf 'worktree=%s\n' "$path"
  printf 'branch=%s\n' "$branch"
  printf 'runtime_task=%s\n' "$rtask"
  printf 'dispatch=%s\n' "$dispatch_id"
  printf 'confirmed=working\n'
  [ "$REPAIRS" -gt 0 ] && printf 'repaired=%s\n' "$REPAIRS"
  printf 'note=Worker observed processing its brief in an Orca-managed workspace, visible in the app.\n'
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
# The first --until-file that exists, or nothing.
#
# pipeline.sh writes homolog-approved.txt, node-failed.txt and ask.md in bash,
# the instant each happens. The runtime's worker_done, by contrast, is a message
# the worker LLM sends when it gets round to it — so the artifact is always on
# disk first, sometimes by minutes. Watching the disk is what makes the window
# end when the thing actually happened, rather than when someone mentioned it.
first_existing() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$f" ] && { printf '%s' "$f"; return 0; }
  done <<EOF
$UNTIL_FILES
EOF
  return 1
}

# `done=` is deliberately NOT emitted. A worker_done message is a hint that a
# worker thinks it finished; graph.sh poll decides it, by reading the
# workspace's own homolog-approved.txt. An artifact seen here is the same kind
# of hint: it ends the wait window early and decides nothing.
verb_wait() {
  require_state
  require_cli

  local run coordinator
  run="$(cat "$STATE/driver-orca-run.txt" 2>/dev/null || true)"
  coordinator="$(cat "$STATE/driver-orca-coordinator.txt" 2>/dev/null || true)"

  # Already there before the first block: a run that finished while the previous
  # turn was being taken must not buy another full window.
  local hit
  hit="$(first_existing || true)"
  if [ -n "$hit" ]; then
    printf 'artifact=%s\n' "$hit"
    printf 'signal=artifact\n'
    return 0
  fi

  # The window is spent in slices instead of one call. Between them the disk is
  # checked, which is the only signal that tracks reality; the runtime channel
  # is still listened to, because an escalation only ever arrives that way.
  # The total blocked time is unchanged, so the caller's pacing is unchanged.
  local slice_ms=15000 deadline began now_s left_ms out
  began="$(date +%s)"
  deadline=$(( began + TIMEOUT_MS / 1000 ))

  while :; do
    now_s="$(date +%s)"
    left_ms=$(( (deadline - now_s) * 1000 ))
    [ "$left_ms" -gt 0 ] || break
    [ "$left_ms" -lt "$slice_ms" ] && slice_ms="$left_ms"

    # The runtime replays the SAME delivery until it is acknowledged — `orca
    # orchestration check --help`: "A bound Run replays the same Delivery until
    # --ack; process every message before acknowledging." This driver never
    # acked, so once any message landed in the coordinator's queue every later
    # `check --wait` answered with that stale batch the instant it was called
    # and the wait window collapsed to zero.
    local ack args=()
    ack="$(cat "$STATE/driver-orca-delivery.txt" 2>/dev/null || true)"
    args=(orchestration check --wait --types worker_done,escalation --timeout-ms "$slice_ms" --json)
    [ -n "$run" ] && args+=(--run "$run")
    [ -n "$coordinator" ] && args+=(--terminal "$coordinator")
    [ -n "$ack" ] && args+=(--ack "$ack")

    # stderr carries the 15s keepalives, never results.
    out="$(orca "${args[@]}" 2>/dev/null || true)"

    # Whatever delivery this batch belongs to is acked on the NEXT call. Written
    # before anything else so a caller that dies mid-turn still stops the replay.
    local delivery
    delivery="$(printf '%s' "$out" | json_val deliveryId)"
    [ -n "$delivery" ] || delivery="$(printf '%s' "$out" | json_val delivery_id)"
    [ -n "$delivery" ] || delivery="$(printf '%s' "$out" \
      | sed -n 's/.*"delivery"[[:space:]]*:[[:space:]]*{[^}]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$delivery" ] && printf '%s\n' "$delivery" > "$STATE/driver-orca-delivery.txt"

    # An `ok:false` answer used to be indistinguishable from a quiet five
    # minutes: stderr discarded, the exit code swallowed by `|| true`, and the
    # empty parse falling through to `timeout=1`. A call that FAILED in 50ms
    # then read to the graph exactly like a wait window that closed.
    if printf '%s' "$out" | grep -q '"ok"[[:space:]]*:[[:space:]]*false'; then
      printf 'error=%s\n' "$(printf '%s' "$out" | json_val code)"
    fi

    if printf '%s' "$out" | grep -q '"type"[[:space:]]*:[[:space:]]*"escalation"'; then
      printf 'signal=escalation\n'
      return 0
    fi

    local payload last
    payload="$(printf '%s' "$out" | grep -oE 'task_[0-9a-zA-Z]+' | head -1 || true)"
    # The same payload twice running is the replay, not a second worker
    # finishing. Reporting it again is what turned the wait into a busy loop.
    last="$(cat "$STATE/driver-orca-last-signal.txt" 2>/dev/null || true)"
    if [ -n "$payload" ] && [ "$payload" != "$last" ]; then
      printf '%s\n' "$payload" > "$STATE/driver-orca-last-signal.txt"
      local f rtask task
      for f in "$STATE"/driver-orca-*.txt; do
        [ -f "$f" ] || continue
        rtask="$(kv_get "$f" runtime_task)"
        [ "$rtask" = "$payload" ] || continue
        task="$(basename "$f" .txt)"
        task="${task#driver-orca-}"
        printf 'reported=%s\n' "$task"
      done
      printf 'signal=worker_done\n'
      return 0
    fi

    hit="$(first_existing || true)"
    if [ -n "$hit" ]; then
      printf 'artifact=%s\n' "$hit"
      printf 'signal=artifact\n'
      printf 'waited=%s\n' "$(( $(date +%s) - began ))"
      return 0
    fi
  done

  # A timeout is a checkpoint, not a failure: coding tasks routinely run long.
  printf 'waited=%s\n' "$(( $(date +%s) - began ))"
  printf 'timeout=1\n'
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
  # a PR waiting to be merged) belong to no task, so they go back to the user in
  # context.
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

# Wakes a worker that ended its turn waiting on the coordinator. The pipeline's
# answer is already on disk; what the worker lacks is a reason to look — this
# types one into its pane. Measured live: without it, workers polled a channel
# that never delivered, and the coordinator unblocked them by hand three times.
verb_resume() {
  local task="${REST[0]:-}" message="${REST[1]:-}"
  [ -n "$task" ] || { echo "driver-orca.sh resume: <task> is required" >&2; exit 1; }
  require_state
  require_cli

  local f="$STATE/driver-orca-$task.txt" handle
  handle="$(kv_get "$f" handle)"
  [ -n "$handle" ] || { echo "driver-orca.sh resume: no terminal handle recorded for $task" >&2; exit 1; }

  local text="${message:-The coordinator answered — re-run pipeline.sh next $task and continue.}"
  # One line, then a separate Enter: a paste never submits itself (the trailing
  # newline of --enter is eaten as part of the paste — measured in dispatch).
  orca terminal send --terminal "$handle" --text "$text" >/dev/null 2>&1 || {
    printf 'resumed=0\n'
    printf 'handle=%s\n' "$handle"
    printf 'reason=terminal send failed — the pane may be gone; re-list it or stop the node\n'
    exit 1
  }
  sleep 1
  orca terminal send --terminal "$handle" --text "" --enter >/dev/null 2>&1 || true
  printf 'resumed=1\n'
  printf 'handle=%s\n' "$handle"
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
  resume)   verb_resume ;;
  stop)     verb_stop ;;
  probe)    verb_probe ;;
  *)        usage; exit 1 ;;
esac
