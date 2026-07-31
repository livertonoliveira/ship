#!/usr/bin/env bash

set -euo pipefail

# The Orca driver died on its FIRST call for weeks and nothing caught it, because
# every test around graph mode used driver-local and the only thing exercising
# this file was a real run. When the runtime retired `coordinator-start`, a
# `task-create` with no `--run` started answering `legacy_read_only`, no workspace
# was ever created, and the graph fell back to the driver that opens nothing.
#
# This pins the call SHAPE against a fake `orca` on PATH, so the contract is
# checked in CI with no runtime installed. It cannot prove the live API still
# accepts these calls — only a real dispatch does that — but it does stop the
# calls silently drifting back to a shape that was measured not to work.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/../driver-orca.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A fake `orca` that records every argv line and answers each subcommand with the
# minimum the driver parses out of it.
new_fake_orca() {
  local root="$1"
  mkdir -p "$root/bin"
  cat > "$root/bin/orca" <<'EOF'
#!/usr/bin/env bash
# One line per call even when an argument is multi-line — the log is read with
# line-oriented greps, and a multi-line --spec silently truncated every
# assertion about the flags that came after it.
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$ORCA_FAKE_LOG"

# A pane, modelled on the one that was measured. ORCA_FAKE_TUI picks which
# failure it reproduces:
#   dirty  — worker-start pasted the brief and never submitted it (what the five
#            live workers did). A bare Enter starts it.
#   clean  — the brief never arrived at all. Needs pasting, then Enter.
#   stuck  — nothing ever revives it; dispatch must refuse to report ok=1.
#   busy   — the runtime kept its promise.
tui_state() { cat "$ORCA_FAKE_TUI_STATE" 2>/dev/null || printf '%s' "${ORCA_FAKE_TUI:-dirty}"; }
tui_set() { printf '%s' "$1" > "$ORCA_FAKE_TUI_STATE"; }

case "$1 ${2:-}" in
  "terminal read")
    case "$(tui_state)" in
      busy)
        # A working TUI redraws its status line, so consecutive reads differ.
        n=$(( $(cat "$ORCA_FAKE_TICK" 2>/dev/null || echo 0) + 1 ))
        printf '%s' "$n" > "$ORCA_FAKE_TICK"
        printf '⏺ working\n✻ Stewing… (%ss · ↓ %s tokens)\n❯\n  ⏵⏵ bypass permissions on\n' "$n" "$n" ;;
      dirty)
        printf '⏺ ready\n❯ /ship:run N1 — the whole brief, pasted and unsent\n  ⏵⏵ bypass permissions on\n' ;;
      *)
        printf '⏺ ready\n❯\n  ⏵⏵ bypass permissions on\n' ;;
    esac
    exit 0 ;;
  "terminal send")
    if printf '%s' "$*" | grep -q -- '--enter'; then
      [ "$(tui_state)" = "dirty" ] && tui_set busy
    else
      [ "$(tui_state)" = "clean" ] && tui_set dirty
    fi
    printf '{ "ok": true, "result": {} }'
    exit 0 ;;
esac

case "$1 ${2:-}" in
  "orchestration run-create")
    printf '{ "ok": true, "result": { "run": { "id": "run_deadbeef01" } } }' ;;
  "orchestration task-create")
    printf '{ "ok": true, "result": { "task": { "id": "task_deadbeef02", "created_by_terminal_handle": "term_c" } } }' ;;
  "orchestration worker-start")
    printf '{ "ok": true, "result": { "dispatchId": "ctx_deadbeef03", "effects": [ { "id": "repo1::/tmp/ws/N1" }, { "id": "term_w1" } ] } }' ;;
  "worktree show")
    printf '{ "ok": true, "result": { "path": "/tmp/ws/N1", "branch": "refs/heads/ship/N1", "baseRef": "main" } }' ;;
  "repo list")
    printf '{ "id": "envelope-uuid", "ok": true, "result": { "repos": [ { "id": "REPO-ID-HERE", "path": "REPO-PATH-HERE" } ] } }' ;;
  "status "*|"status")
    printf '{ "ok": true, "result": { "runtime": { "reachable": true } } }' ;;
  *) printf '{ "ok": true, "result": {} }' ;;
esac
EOF
  chmod +x "$root/bin/orca"
}

# Dispatch once inside a git repo the fake registers, and hand back the argv log.
run_dispatch() {
  local root="$1"; shift
  local repo="$root/repo" state="$root/state" rc=0
  mkdir -p "$repo" "$state"
  (
    cd "$repo"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    git commit -q --allow-empty -m init
  )
  local top
  top="$(cd "$repo" && git rev-parse --path-format=absolute --git-common-dir)"
  top="$(dirname "$top")"
  sed -i.bak -e "s#REPO-PATH-HERE#$top#" -e "s#REPO-ID-HERE#repo-from-cwd#" "$root/bin/orca"

  # From INSIDE the repo: resolving the repo from the working tree is part of the
  # contract, so the caller's cwd is not incidental here.
  ( cd "$repo" && ORCA_FAKE_LOG="$root/argv.log" PATH="$root/bin:$PATH" \
    ORCA_FAKE_TUI="${ORCA_FAKE_TUI:-dirty}" ORCA_FAKE_TUI_STATE="$root/tui" ORCA_FAKE_TICK="$root/tick" \
    SHIP_ORCA_BUSY_SAMPLE_S=0 \
    bash "$DRIVER" dispatch N1 "/ship:run N1" --state "$state" --base main "$@" ) \
    >"$root/out.txt" 2>"$root/err.txt" || rc=$?
  printf '%s' "$rc" > "$root/rc.txt"
}

new_case() {
  local root
  root="$(mktemp -d)"
  new_fake_orca "$root"
  printf '%s' "$root"
}

# --- the exact failure that was measured -------------------------------------

test_a_run_is_created_before_anything_else() {
  local root
  local first
  root="$(new_case)"; run_dispatch "$root"
  first="$(grep '^orchestration ' "$root/argv.log" | head -1)"
  if printf '%s' "$first" | grep -q '^orchestration run-create '; then
    log_pass "dispatch opens a Run before any other orchestration call"
  else
    log_fail "dispatch opens a Run before any other orchestration call (first was: $first)"
  fi
  rm -rf "$root"
}

test_task_create_carries_the_run() {
  local root line
  root="$(new_case)"; run_dispatch "$root"
  line="$(grep '^orchestration task-create ' "$root/argv.log" | head -1)"
  # Without --run, task-create falls back to the retired coordinator lookup and
  # answers legacy_read_only. This one flag is the whole difference.
  if printf '%s' "$line" | grep -q -- '--run run_deadbeef01'; then
    log_pass "task-create carries the Run (the flag whose absence returned legacy_read_only)"
  else
    log_fail "task-create carries the Run (got: $line)"
  fi
  rm -rf "$root"
}

test_the_retired_call_is_never_made() {
  local root
  root="$(new_case)"; run_dispatch "$root"
  if grep -q 'coordinator-start' "$root/argv.log"; then
    log_fail "the retired coordinator-start scheme is never called"
  else
    log_pass "the retired coordinator-start scheme is never called"
  fi
  rm -rf "$root"
}

# --- and the workspace it has to produce -------------------------------------

test_worker_start_creates_a_workspace_through_the_runtime() {
  local root line
  root="$(new_case)"; run_dispatch "$root"
  line="$(grep '^orchestration worker-start ' "$root/argv.log" | head -1)"
  # Created THROUGH the runtime is what registers it with the app; a plain git
  # worktree beside the repo never shows up there.
  if printf '%s' "$line" | grep -q -- '--worktree new-top-level' \
     && printf '%s' "$line" | grep -q -- '--run run_deadbeef01' \
     && printf '%s' "$line" | grep -q -- '--task task_deadbeef02'; then
    log_pass "worker-start asks the runtime for a new top-level workspace on the Run's task"
  else
    log_fail "worker-start asks the runtime for a new top-level workspace on the Run's task (got: $line)"
  fi
  rm -rf "$root"
}

test_one_workspace_named_for_the_node() {
  local root line
  root="$(new_case)"; run_dispatch "$root"
  line="$(grep '^orchestration worker-start ' "$root/argv.log" | head -1)"
  if printf '%s' "$line" | grep -q -- '--name N1' && printf '%s' "$line" | grep -q -- '--display-name N1'; then
    log_pass "the workspace is named for the node, so one node reads as one workspace"
  else
    log_fail "the workspace is named for the node (got: $line)"
  fi
  rm -rf "$root"
}

test_an_agent_is_launched_in_it() {
  local root line
  root="$(new_case)"; run_dispatch "$root"
  line="$(grep '^orchestration worker-start ' "$root/argv.log" | head -1)"
  # A workspace with no agent in it is the failure mode driver-local had: the
  # checkout exists and nothing is working in it.
  if printf '%s' "$line" | grep -qE -- '--agent |--terminal '; then
    log_pass "worker-start launches an agent in the workspace it creates"
  else
    log_fail "worker-start launches an agent in the workspace it creates (got: $line)"
  fi
  rm -rf "$root"
}

test_dispatch_reports_the_workspace_it_made() {
  local root out
  root="$(new_case)"; run_dispatch "$root"
  out="$(cat "$root/out.txt")"
  if printf '%s' "$out" | grep -q '^ok=1$' \
     && printf '%s' "$out" | grep -q '^worktree=/tmp/ws/N1$' \
     && printf '%s' "$out" | grep -q '^branch=ship/N1$'; then
    log_pass "dispatch reports the workspace path and short branch back to the graph"
  else
    # stderr too: an empty stdout means the driver died before printing, and the
    # reason is only ever on the other stream.
    log_fail "dispatch reports the workspace path and short branch back to the graph (stdout: $out / stderr: $(cat "$root/err.txt"))"
  fi
  rm -rf "$root"
}

# --- the worker has to be OBSERVED working -----------------------------------
#
# Measured 2026-07-30: worker-start delivered five briefs in one burst and
# submitted none of them. Five workers sat idle with the whole brief pasted at
# their prompt while the graph reported all five dispatched and waited on them
# for half an hour. The driver had deleted its paste-verify-Enter repair on the
# strength of worker-start's documented "delivers as accepted input".

test_an_unsent_brief_is_submitted() {
  local root
  root="$(new_case)"; ORCA_FAKE_TUI=dirty run_dispatch "$root"
  # A pane holding an unsent brief needs a BARE Enter as its own keystroke — the
  # trailing newline of a paste is consumed by the paste itself.
  if grep -q 'terminal send .*--enter' "$root/argv.log"; then
    log_pass "a brief left unsent in the prompt gets the Enter the runtime never sent"
  else
    log_fail "a brief left unsent in the prompt gets the Enter the runtime never sent"
  fi
  rm -rf "$root"
}

test_a_brief_that_never_arrived_is_delivered() {
  local root
  root="$(new_case)"; ORCA_FAKE_TUI=clean run_dispatch "$root"
  if grep -q 'terminal send .*--text ' "$root/argv.log" && grep -q 'terminal send .*--enter' "$root/argv.log"; then
    log_pass "a brief that never arrived is pasted and then submitted"
  else
    log_fail "a brief that never arrived is pasted and then submitted (log: $(grep -c 'terminal send' "$root/argv.log") sends)"
  fi
  rm -rf "$root"
}

test_dispatch_refuses_to_report_a_worker_it_cannot_see_working() {
  local root out
  root="$(new_case)"; ORCA_FAKE_TUI=stuck run_dispatch "$root"
  out="$(cat "$root/out.txt")"
  # The whole bug in one assertion: reporting ok=1 on the runtime's promise is
  # what let five dead nodes be claimed in_flight.
  if [ "$(cat "$root/rc.txt")" != "0" ] && printf '%s' "$out" | grep -q '^ok=0$' \
     && ! printf '%s' "$out" | grep -q '^ok=1$'; then
    log_pass "a worker that never starts working fails the dispatch instead of being reported started"
  else
    log_fail "a worker that never starts working fails the dispatch (rc: $(cat "$root/rc.txt") / stdout: $out)"
  fi
  rm -rf "$root"
}

test_an_unconfirmed_worker_is_still_stoppable() {
  local root
  root="$(new_case)"; ORCA_FAKE_TUI=stuck run_dispatch "$root"
  # Exiting without recording the handle would strand a live agent billing in a
  # workspace nothing knows about.
  if grep -q '^handle=' "$root/state/driver-orca-N1.txt" 2>/dev/null; then
    log_pass "a dispatch that fails confirmation still records the workspace it left behind"
  else
    log_fail "a dispatch that fails confirmation still records the workspace it left behind"
  fi
  rm -rf "$root"
}

test_a_working_worker_is_reported_confirmed() {
  local root out
  root="$(new_case)"; ORCA_FAKE_TUI=busy run_dispatch "$root"
  out="$(cat "$root/out.txt")"
  if printf '%s' "$out" | grep -q '^confirmed=working$'; then
    log_pass "dispatch reports confirmation as evidence, not as a claim"
  else
    log_fail "dispatch reports confirmation as evidence (stdout: $out)"
  fi
  rm -rf "$root"
}

test_a_working_worker_is_not_disturbed() {
  local root
  root="$(new_case)"; ORCA_FAKE_TUI=busy run_dispatch "$root"
  # Pressing Enter into a working agent injects a stray turn into its session.
  if grep -q 'terminal send' "$root/argv.log"; then
    log_fail "a worker already working is left alone (it was sent input anyway)"
  else
    log_pass "a worker already working is left alone"
  fi
  rm -rf "$root"
}

test_the_worker_is_told_how_to_report_completion() {
  local root line
  root="$(new_case)"; run_dispatch "$root"
  line="$(grep '^orchestration task-create ' "$root/argv.log" | head -1)"
  # Measured: worker_done without --run is rejected as legacy_read_only, and the
  # runtime's own preamble never mentions the Run. Workers retried it forever.
  if printf '%s' "$line" | grep -q -- '--run run_deadbeef01 in addition to'; then
    log_pass "the brief tells the worker to carry the Run on its completion call"
  else
    log_fail "the brief tells the worker to carry the Run on its completion call (got: $line)"
  fi
  rm -rf "$root"
}

test_concurrent_dispatches_share_one_run() {
  local root state repo
  root="$(new_case)"; run_dispatch "$root"   # seeds the repo and the first node
  state="$root/state" repo="$root/repo"
  rm -f "$state/driver-orca-run.txt"
  : > "$root/argv.log"

  # A graph dispatches its whole frontier at once. Measured live: two dispatches
  # racing here each created a Run, and the loser's task-create came back
  # consumer_fenced — the coordinator terminal binds to exactly one Run, so that
  # node never started at all.
  local n
  for n in P1 P2 P3; do
    ( cd "$repo" && ORCA_FAKE_LOG="$root/argv.log" PATH="$root/bin:$PATH" \
      ORCA_FAKE_TUI=busy ORCA_FAKE_TUI_STATE="$root/tui-$n" ORCA_FAKE_TICK="$root/tick-$n" \
      SHIP_ORCA_BUSY_SAMPLE_S=0 \
      bash "$DRIVER" dispatch "$n" "/ship:run $n" --state "$state" --base main >/dev/null 2>&1 ) &
  done
  wait

  if [ "$(grep -c '^orchestration run-create ' "$root/argv.log")" -eq 1 ]; then
    log_pass "dispatches racing for the same graph create exactly one Run"
  else
    log_fail "dispatches racing for the same graph create exactly one Run (created $(grep -c '^orchestration run-create ' "$root/argv.log"))"
  fi
  rm -rf "$root"
}

# --- the right repo ----------------------------------------------------------

test_repo_is_resolved_from_the_working_tree() {
  local root line
  root="$(new_case)"; run_dispatch "$root"
  line="$(grep '^orchestration worker-start ' "$root/argv.log" | head -1)"
  # With --repo omitted the runtime would infer the CALLING terminal's checkout,
  # which is the coordinator's, not necessarily the graph's.
  if printf '%s' "$line" | grep -q -- '--repo id:repo-from-cwd'; then
    log_pass "an omitted repo is resolved from the working tree, not left to inference"
  else
    log_fail "an omitted repo is resolved from the working tree (got: $line)"
  fi
  rm -rf "$root"
}

test_an_explicit_repo_wins() {
  local root line
  root="$(new_case)"; run_dispatch "$root" --repo given-repo-id
  line="$(grep '^orchestration worker-start ' "$root/argv.log" | head -1)"
  if printf '%s' "$line" | grep -q -- '--repo id:given-repo-id'; then
    log_pass "a repo passed by the graph is used as given"
  else
    log_fail "a repo passed by the graph is used as given (got: $line)"
  fi
  rm -rf "$root"
}

# --- the Run is not re-created per node --------------------------------------

test_the_run_is_reused_across_dispatches() {
  local root state
  root="$(new_case)"; run_dispatch "$root"
  state="$root/state"
  # The fake's pane state has to be wired here too: without it the driver runs
  # its real repair loop against a pane that never revives, and this assertion
  # about run-create pays for six delivery attempts to learn nothing.
  ORCA_FAKE_LOG="$root/argv.log" PATH="$root/bin:$PATH" \
    ORCA_FAKE_TUI=busy ORCA_FAKE_TUI_STATE="$root/tui-n2" ORCA_FAKE_TICK="$root/tick-n2" \
    SHIP_ORCA_BUSY_SAMPLE_S=0 \
    bash "$DRIVER" dispatch N2 "/ship:run N2" --state "$state" --base main >/dev/null 2>&1 || true

  if [ "$(grep -c '^orchestration run-create ' "$root/argv.log")" -eq 1 ]; then
    log_pass "the Run is created once and reused by every later node"
  else
    log_fail "the Run is created once and reused by every later node"
  fi
  rm -rf "$root"
}

test_a_probe_reads_the_runtime_not_just_the_path() {
  local root out
  root="$(new_case)"
  out="$(ORCA_FAKE_LOG="$root/argv.log" PATH="$root/bin:$PATH" bash "$DRIVER" probe)"
  # The CLI answers fine with the app closed; a graph electing this driver on
  # PATH alone would fail at its first dispatch.
  if grep -q '^status' "$root/argv.log" && printf '%s' "$out" | grep -q '^ready=1$'; then
    log_pass "probe asks the runtime whether it is reachable"
  else
    log_fail "probe asks the runtime whether it is reachable (log: $(cat "$root/argv.log"))"
  fi
  rm -rf "$root"
}

test_a_probe_declares_its_workspaces() {
  local root out
  root="$(new_case)"
  out="$(ORCA_FAKE_LOG="$root/argv.log" PATH="$root/bin:$PATH" bash "$DRIVER" probe)"
  if printf '%s' "$out" | grep -q '^workspaces=.*visible in the app'; then
    log_pass "probe states that its workspaces show in the app"
  else
    log_fail "probe states that its workspaces show in the app (got: $out)"
  fi
  rm -rf "$root"
}

test_a_run_is_created_before_anything_else
test_task_create_carries_the_run
test_the_retired_call_is_never_made
test_worker_start_creates_a_workspace_through_the_runtime
test_one_workspace_named_for_the_node
test_an_agent_is_launched_in_it
test_dispatch_reports_the_workspace_it_made
test_an_unsent_brief_is_submitted
test_a_brief_that_never_arrived_is_delivered
test_dispatch_refuses_to_report_a_worker_it_cannot_see_working
test_an_unconfirmed_worker_is_still_stoppable
test_a_working_worker_is_reported_confirmed
test_a_working_worker_is_not_disturbed
test_the_worker_is_told_how_to_report_completion
test_concurrent_dispatches_share_one_run
test_repo_is_resolved_from_the_working_tree
test_an_explicit_repo_wins
test_the_run_is_reused_across_dispatches
test_a_probe_reads_the_runtime_not_just_the_path
test_a_probe_declares_its_workspaces

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
