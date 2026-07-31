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
printf '%s\n' "$*" >> "$ORCA_FAKE_LOG"
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
  local repo="$root/repo" state="$root/state"
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
    bash "$DRIVER" dispatch N1 "/ship:run N1" --state "$state" --base main "$@" ) \
    >"$root/out.txt" 2>"$root/err.txt" || true
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
    log_fail "dispatch reports the workspace path and short branch back to the graph (got: $out)"
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
  ORCA_FAKE_LOG="$root/argv.log" PATH="$root/bin:$PATH" \
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
test_repo_is_resolved_from_the_working_tree
test_an_explicit_repo_wins
test_the_run_is_reused_across_dispatches
test_a_probe_reads_the_runtime_not_just_the_path
test_a_probe_declares_its_workspaces

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
