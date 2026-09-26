#!/usr/bin/env bash

set -euo pipefail

# A dispatch that fails never reaches `claim`, so the node stays pending and the
# next `next` dispatches it again. Measured 2026-09-25: four dispatches of one
# node before one took, each leaving a workspace behind, and not one line about
# it in graph-log.md. The driver records the failure; `next` counts it, logs it
# and, past a cap, fails the node with a hold instead of retrying every turn.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

new_sandbox() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/repo"
  (
    cd "$root/repo"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    mkdir -p ship
    printf -- '- Test Framework: none\n' > ship/config.md
    cat > nodes.json <<'JSON'
[ { "id": "N1", "title": "One", "deps": [], "files": ["src/a.ts"] },
  { "id": "N2", "title": "Two", "deps": ["N1"], "files": ["src/b.ts"] } ]
JSON
    bash "$GRAPH" init --feature f --from nodes.json --driver local --max-in-flight 1 --mode local >/dev/null
  )
  printf '%s' "$root"
}

fail_dispatch() {
  printf 'the runtime refused to start N1 — pty spawn failed\n' > "$1/repo/.context/ship-graph/f/dispatch-failed-N1.txt"
  ( cd "$1/repo" && bash "$GRAPH" next >/dev/null )
}

status_of() {
  jq -r --arg id "$2" '.nodes[] | select(.id == $id) | .status' "$1/repo/.context/ship-graph/f/graph.json"
}

test_a_failed_dispatch_is_logged_and_retried() {
  local root log
  root="$(new_sandbox)"
  fail_dispatch "$root"
  log="$root/repo/.context/ship-graph/f/graph-log.md"
  if grep -q 'N1 dispatch failed (1 of 5): the runtime refused to start N1 — pty spawn failed — dispatching again' "$log" \
     && [ "$(status_of "$root" N1)" = "pending" ] \
     && [ ! -e "$root/repo/.context/ship-graph/f/dispatch-failed-N1.txt" ]; then
    log_pass "a failed dispatch is logged with its reason, consumed, and the node stays on the frontier"
  else
    log_fail "a failed dispatch is logged with its reason, consumed, and the node stays on the frontier"
  fi
  rm -rf "$root"
}

test_a_node_that_never_dispatches_fails_at_the_cap() {
  local root i dir
  root="$(new_sandbox)"; dir="$root/repo/.context/ship-graph/f"
  for i in 1 2 3 4 5; do fail_dispatch "$root"; done
  if [ "$(status_of "$root" N1)" = "failed" ] && [ -f "$dir/hold-N1.txt" ] \
     && grep -q 'N1 → failed: dispatch failed 5 of 5 time(s)' "$dir/graph-log.md"; then
    log_pass "a node whose dispatch keeps failing is failed with a hold at the cap, not dispatched every turn"
  else
    log_fail "a node whose dispatch keeps failing is failed with a hold at the cap, not dispatched every turn"
  fi
  rm -rf "$root"
}

test_a_failed_node_is_not_handed_straight_back() {
  local root i
  root="$(new_sandbox)"
  for i in 1 2 3 4 5; do fail_dispatch "$root"; done
  ( cd "$root/repo" && bash "$GRAPH" next >/dev/null )
  if [ "$(status_of "$root" N1)" = "failed" ]; then
    log_pass "the automatic retry pass leaves a dispatch-failed node for reset"
  else
    log_fail "the automatic retry pass leaves a dispatch-failed node for reset"
  fi
  rm -rf "$root"
}

test_reset_starts_the_count_over() {
  local root i dir
  root="$(new_sandbox)"; dir="$root/repo/.context/ship-graph/f"
  for i in 1 2 3 4 5; do fail_dispatch "$root"; done
  ( cd "$root/repo" && bash "$GRAPH" reset N1 >/dev/null )
  fail_dispatch "$root"
  if [ "$(status_of "$root" N1)" = "pending" ] && grep -q 'N1 dispatch failed (1 of 5)' <(tail -3 "$dir/graph-log.md"); then
    log_pass "reset gives a dispatch-failed node its full count back"
  else
    log_fail "reset gives a dispatch-failed node its full count back"
  fi
  rm -rf "$root"
}

test_a_claim_starts_the_count_over() {
  local root dir
  root="$(new_sandbox)"; dir="$root/repo/.context/ship-graph/f"
  fail_dispatch "$root"
  mkdir -p "$root/ws"
  ( cd "$root/repo" && bash "$GRAPH" claim N1 --worktree "$root/ws" --branch b >/dev/null )
  if [ ! -e "$dir/dispatch-fails-N1.txt" ]; then
    log_pass "a dispatch that takes clears the node's run of failures"
  else
    log_fail "a dispatch that takes clears the node's run of failures"
  fi
  rm -rf "$root"
}

test_a_record_for_a_node_already_running_is_dropped() {
  local root dir
  root="$(new_sandbox)"; dir="$root/repo/.context/ship-graph/f"
  mkdir -p "$root/ws"
  ( cd "$root/repo" && bash "$GRAPH" claim N1 --worktree "$root/ws" --branch b >/dev/null )
  fail_dispatch "$root"
  if [ "$(status_of "$root" N1)" = "in_flight" ] && ! grep -q 'N1 dispatch failed' "$dir/graph-log.md"; then
    log_pass "a stale failure record never moves a node that is already running"
  else
    log_fail "a stale failure record never moves a node that is already running"
  fi
  rm -rf "$root"
}

test_a_failed_dispatch_is_logged_and_retried
test_a_node_that_never_dispatches_fails_at_the_cap
test_a_failed_node_is_not_handed_straight_back
test_reset_starts_the_count_over
test_a_claim_starts_the_count_over
test_a_record_for_a_node_already_running_is_dropped

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
