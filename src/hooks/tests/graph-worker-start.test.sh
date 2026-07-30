#!/usr/bin/env bash

set -euo pipefail

# Regressions from a real run that dispatched 23 nodes and produced no work.
#
# The graph created workspaces, claimed a node in_flight and then waited on a
# worker that had never been started — because `dispatch` for driver-local only
# PREPARES the workspace and returns an `instruction=` line describing the launch
# only the caller can perform, and nothing in `next`'s ordered call list ever
# said to carry it out. Everything here pins a behaviour that failure needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"
DRIVER_LOCAL="$SCRIPT_DIR/../driver-local.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

setup_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    mkdir -p ship
    printf -- '- Test Framework: none\n' > ship/config.md
    cat > nodes.json <<'EOF'
[ { "id": "N1", "title": "One", "deps": [], "files": ["src/a.ts"] },
  { "id": "N2", "title": "Two", "deps": [], "files": ["src/b.ts"] } ]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver local --max-in-flight 2 --mode local >/dev/null
  )
}

# driver-local puts workspaces beside the repo on purpose, so a test repo must be
# disposed of together with its sibling .ship-graph tree.
new_sandbox() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/repo"
  setup_repo "$root/repo"
  printf '%s' "$root"
}

# --- the root cause ----------------------------------------------------------

test_next_orders_the_driver_start_instruction() {
  local root repo out
  root="$(new_sandbox)"; repo="$root/repo"
  out="$(cd "$repo" && bash "$GRAPH" next)"
  # One ordered line per task, between dispatch and collect. Without it a
  # compliant executor runs dispatch/collect/claim and starts nothing.
  if printf '%s' "$out" | grep -q 'instruction=' \
     && [ "$(printf '%s' "$out" | grep -c 'CARRY IT OUT NOW')" -eq 2 ]; then
    log_pass "next orders the driver's start instruction, once per dispatched task"
  else
    log_fail "next orders the driver's start instruction, once per dispatched task"
  fi
  rm -rf "$root"
}

test_dispatch_says_nothing_is_running_yet() {
  local root repo out
  root="$(new_sandbox)"; repo="$root/repo"
  out="$(cd "$repo" && bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main)"
  if printf '%s' "$out" | grep -q 'instruction=REQUIRED' \
     && printf '%s' "$out" | grep -q 'NOTHING is running in it yet'; then
    log_pass "dispatch states that the workspace is prepared but idle"
  else
    log_fail "dispatch states that the workspace is prepared but idle"
  fi
  rm -rf "$root"
}

test_never_started_node_is_named_as_such() {
  local root repo out wt i
  root="$(new_sandbox)"; repo="$root/repo"
  (
    cd "$repo"
    for n in N1 N2; do
      bash "$DRIVER_LOCAL" dispatch "$n" "/ship:run $n" --state ".context/ship-graph/f" --base main >/dev/null
      wt="$(bash "$DRIVER_LOCAL" collect "$n" --state ".context/ship-graph/f" | sed -n 's/^worktree=//p')"
      bash "$GRAPH" claim "$n" --worktree "$wt" --branch "ship/$n" >/dev/null
    done
    for i in 1 2 3; do bash "$GRAPH" poll >/dev/null; done
  )
  out="$(cd "$repo" && bash "$GRAPH" next)"
  # A workspace with no dispatch-log.md at all never ran a phase. Reporting that
  # as a generic stall sends the operator to read a file that does not exist.
  if printf '%s' "$out" | grep -q 'state=ask' \
     && printf '%s' "$out" | grep -q 'worker never started' \
     && printf '%s' "$out" | grep -q 'never ran a single phase'; then
    log_pass "a node whose worker never started is diagnosed, not reported as a generic stall"
  else
    log_fail "a node whose worker never started is diagnosed, not reported as a generic stall"
  fi
  rm -rf "$root"
}

test_poll_flags_never_started_separately() {
  local root repo out wt i
  root="$(new_sandbox)"; repo="$root/repo"
  out="$(
    cd "$repo"
    bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main >/dev/null
    wt="$(bash "$DRIVER_LOCAL" collect N1 --state ".context/ship-graph/f" | sed -n 's/^worktree=//p')"
    bash "$GRAPH" claim N1 --worktree "$wt" --branch ship/N1 >/dev/null
    for i in 1 2 3; do bash "$GRAPH" poll; done
  )"
  if printf '%s' "$out" | grep -q '^never_started=N1$'; then
    log_pass "poll emits never_started= for a workspace no pipeline ever ran in"
  else
    log_fail "poll emits never_started= for a workspace no pipeline ever ran in"
  fi
  rm -rf "$root"
}

# --- worktree lifecycle ------------------------------------------------------

test_retry_reuses_an_orphaned_branch() {
  local root repo out rc=0
  root="$(new_sandbox)"; repo="$root/repo"
  (
    cd "$repo"
    bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main >/dev/null
    git worktree remove --force "$root/.ship-graph/f/N1"
  )
  set +e
  out="$(cd "$repo" && bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main 2>&1)"
  rc=$?
  set -e
  # `git worktree add -b` on a branch that already exists exits 255, and the loop
  # halts on any non-zero driver exit. Retrying a node is normal, so it must not.
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ok=1$'; then
    log_pass "re-dispatch reuses a branch whose workspace was removed"
  else
    log_fail "re-dispatch reuses a branch whose workspace was removed (exit $rc)"
  fi
  rm -rf "$root"
}

test_non_worktree_directory_fails_loudly() {
  local root repo out rc=0
  root="$(new_sandbox)"; repo="$root/repo"
  mkdir -p "$root/.ship-graph/f/N1"
  printf 'debris\n' > "$root/.ship-graph/f/N1/x"
  set +e
  out="$(cd "$repo" && bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main 2>&1)"
  rc=$?
  set -e
  # Reporting ok=1 for a path that is not a repo hands the worker a broken cwd.
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'is not a git worktree'; then
    log_pass "a directory that is not a worktree is refused instead of reported ok"
  else
    log_fail "a directory that is not a worktree is refused instead of reported ok (exit $rc)"
  fi
  rm -rf "$root"
}

# --- state hygiene -----------------------------------------------------------

test_fresh_purges_driver_state() {
  local root repo out
  root="$(new_sandbox)"; repo="$root/repo"
  out="$(
    cd "$repo"
    bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main >/dev/null
    bash "$GRAPH" init --feature f --from nodes.json --driver local --max-in-flight 2 --mode local --fresh >/dev/null
    bash "$DRIVER_LOCAL" wait --state ".context/ship-graph/f"
  )"
  # A completion signal must never survive a reset: before this, the first wait
  # of a brand-new graph reported the previous run's dispatches as finished.
  if ! printf '%s' "$out" | grep -qE '^(done|returned)='; then
    log_pass "--fresh purges driver state so a new graph reports no phantom activity"
  else
    log_fail "--fresh purges driver state so a new graph reports no phantom activity"
  fi
  rm -rf "$root"
}

test_wait_never_claims_completion() {
  local root repo out wt
  root="$(new_sandbox)"; repo="$root/repo"
  out="$(
    cd "$repo"
    bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main >/dev/null
    bash "$DRIVER_LOCAL" wait --state ".context/ship-graph/f"
  )"
  # An Agent returning says the turn ended, not that the pipeline finished.
  # `graph.sh poll` owns that call, and `done=` here read as if the driver did.
  if printf '%s' "$out" | grep -q '^returned=N1$' && ! printf '%s' "$out" | grep -q '^done='; then
    log_pass "wait reports that an agent returned, never that a node is done"
  else
    log_fail "wait reports that an agent returned, never that a node is done"
  fi
  rm -rf "$root"
}

# --- reconfiguring a live graph ----------------------------------------------

test_set_changes_driver_without_touching_nodes() {
  local root repo out nodes_before nodes_after
  root="$(new_sandbox)"; repo="$root/repo"
  nodes_before="$(cd "$repo" && cat .context/ship-graph/f/nodes.tsv)"
  out="$(cd "$repo" && bash "$GRAPH" set --driver manual --max-in-flight 4)"
  nodes_after="$(cd "$repo" && cat .context/ship-graph/f/nodes.tsv)"
  if printf '%s' "$out" | grep -q '^driver=manual$' \
     && printf '%s' "$out" | grep -q '^max_in_flight=4$' \
     && [ "$nodes_before" = "$nodes_after" ]; then
    log_pass "set swaps the driver and the slot count without touching nodes"
  else
    log_fail "set swaps the driver and the slot count without touching nodes"
  fi
  rm -rf "$root"
}

test_set_refuses_to_orphan_an_inflight_worker() {
  local root repo out rc=0 wt
  root="$(new_sandbox)"; repo="$root/repo"
  (
    cd "$repo"
    bash "$DRIVER_LOCAL" dispatch N1 "/ship:run N1" --state ".context/ship-graph/f" --base main >/dev/null
    wt="$(bash "$DRIVER_LOCAL" collect N1 --state ".context/ship-graph/f" | sed -n 's/^worktree=//p')"
    bash "$GRAPH" claim N1 --worktree "$wt" --branch ship/N1 >/dev/null
  )
  set +e
  out="$(cd "$repo" && bash "$GRAPH" set --driver manual 2>&1)"
  rc=$?
  set -e
  # An in-flight node can only be collected, waited on and stopped through the
  # driver that dispatched it.
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'still held by the current one'; then
    log_pass "set refuses a driver swap that would orphan an in-flight worker"
  else
    log_fail "set refuses a driver swap that would orphan an in-flight worker (exit $rc)"
  fi
  rm -rf "$root"
}

test_resume_points_at_set_not_fresh() {
  local root repo out rc=0
  root="$(new_sandbox)"; repo="$root/repo"
  set +e
  out="$(cd "$repo" && bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 5 --mode local 2>&1)"
  rc=$?
  set -e
  # The reflex this prevents: a refused re-init whose only documented escape is
  # --fresh, which discards the very counters the refusal exists to protect.
  if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q '^reconfigure=graph.sh set '; then
    log_pass "a refused re-init names the non-destructive way to change the same knobs"
  else
    log_fail "a refused re-init names the non-destructive way to change the same knobs (exit $rc)"
  fi
  rm -rf "$root"
}

test_unreadable_slot_count_is_not_a_deadlock() {
  local root repo out
  root="$(new_sandbox)"; repo="$root/repo"
  (
    cd "$repo"
    awk -F'\t' -v OFS='\t' '$1 == "max_in_flight" { $2 = "" } { print }' \
      .context/ship-graph/f/meta.tsv > .context/ship-graph/f/m.tmp
    mv .context/ship-graph/f/m.tmp .context/ship-graph/f/meta.tsv
  )
  out="$(cd "$repo" && bash "$GRAPH" next)"
  # Empty is 0 in bash arithmetic, so an unreadable count used to yield zero free
  # slots and report a deadlock over a graph whose nodes were all admissible.
  if printf '%s' "$out" | grep -q '^state=frontier$'; then
    log_pass "an unreadable slot count falls back to one slot instead of faking a deadlock"
  else
    log_fail "an unreadable slot count falls back to one slot instead of faking a deadlock"
  fi
  rm -rf "$root"
}

test_missing_driver_file_is_named() {
  local root repo out rc=0
  root="$(new_sandbox)"; repo="$root/repo"
  (
    cd "$repo"
    awk -F'\t' -v OFS='\t' '$1 == "driver" { $2 = "ghost" } { print }' \
      .context/ship-graph/f/meta.tsv > .context/ship-graph/f/m.tmp
    mv .context/ship-graph/f/m.tmp .context/ship-graph/f/meta.tsv
  )
  set +e
  out="$(cd "$repo" && bash "$GRAPH" next 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'does not exist'; then
    log_pass "a meta pointing at a driver that does not exist fails by name"
  else
    log_fail "a meta pointing at a driver that does not exist fails by name (exit $rc)"
  fi
  rm -rf "$root"
}

test_next_orders_the_driver_start_instruction
test_dispatch_says_nothing_is_running_yet
test_never_started_node_is_named_as_such
test_poll_flags_never_started_separately
test_retry_reuses_an_orphaned_branch
test_non_worktree_directory_fails_loudly
test_fresh_purges_driver_state
test_wait_never_claims_completion
test_set_changes_driver_without_touching_nodes
test_set_refuses_to_orphan_an_inflight_worker
test_resume_points_at_set_not_fresh
test_unreadable_slot_count_is_not_a_deadlock
test_missing_driver_file_is_named

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
