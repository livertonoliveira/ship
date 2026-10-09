#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../subagent-lifecycle.sh"

pass_count=0
fail_count=0

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

# A workspace whose pipeline just dispatched <name>.
new_run() {
  local dir name="$1" age="${2:-5}"
  dir="$(mktemp -d)"
  mkdir -p "$dir/.context/ship-run/MOB-1"
  printf '%s\tquality\tAgent\t%s\n' "$(( $(date -u +%s) - age ))" "$name" > "$dir/.context/ship-run/MOB-1/timings.tsv"
  printf '%s' "$dir"
}

event() {
  local dir="$1" type="$2" id="$3" extra="${4:-}"
  printf '{"session_id":"s","cwd":"%s","agent_type":"%s","agent_id":"%s"%s}' "$dir" "$type" "$id" "$extra"
}

run_hook() {
  local verb="$1" payload="$2" rc=0
  printf '%s' "$payload" | bash "$HOOK" "$verb" 2>"$TMP_ERR" || rc=$?
  return "$rc"
}

TMP_ERR="$(mktemp)"

test_start_records_the_worker() {
  local name="start writes the start epoch and the agent id for a worker the pipeline dispatched"
  local dir f
  dir="$(new_run ship-review)"
  run_hook start "$(event "$dir" ship:ship-review agent-1)"
  f="$dir/.context/ship-run/MOB-1/worker-start-ship-review.txt"
  if [ "$(sed -n 2p "$f" 2>/dev/null)" = "agent-1" ] && [ -n "$(sed -n 1p "$f" | tr -cd '0-9')" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_start_ignores_a_stale_run() {
  local name="start leaves a run alone when its dispatch is older than 15 minutes"
  local dir
  dir="$(new_run ship-review 3600)"
  run_hook start "$(event "$dir" ship:ship-review agent-1)"
  if [ ! -e "$dir/.context/ship-run/MOB-1/worker-start-ship-review.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_a_blocked_stop_leaves_a_record() {
  local name="a stop blocked for missing files records that the worker tried to end"
  local dir rc=0
  dir="$(new_run ship-security)"
  run_hook start "$(event "$dir" ship:ship-security agent-9)"
  run_hook stop "$(event "$dir" ship:ship-security agent-9 ',"stop_hook_active":false')" || rc=$?
  if [ "$rc" -eq 2 ] && [ -s "$dir/.context/ship-run/MOB-1/worker-ended-ship-security.txt" ] \
     && [ ! -e "$dir/.context/ship-run/MOB-1/worker-done-ship-security.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
  rm -rf "$dir"
}

test_stop_blocks_until_the_files_exist() {
  local name="stop blocks a worker that wrote nothing, then lets it finish once it has and marks it done"
  local dir rc=0 rc2=0
  dir="$(new_run ship-test-unit)"
  run_hook start "$(event "$dir" ship:ship-test-unit agent-7)"
  sleep 1
  run_hook stop "$(event "$dir" ship:ship-test-unit agent-7 ',"stop_hook_active":false')" || rc=$?
  local err
  err="$(cat "$TMP_ERR")"
  : > "$dir/.context/ship-run/MOB-1/generated-tests-unit.md"
  echo "Status: DONE" > "$dir/.context/ship-run/MOB-1/worker-status-unit.md"
  run_hook stop "$(event "$dir" ship:ship-test-unit agent-7 ',"stop_hook_active":false')" || rc2=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'generated-tests-unit.md' \
     && printf '%s' "$err" | grep -q 'worker-status-unit.md' && [ "$rc2" -eq 0 ] \
     && [ -s "$dir/.context/ship-run/MOB-1/worker-done-ship-test-unit.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc rc2=$rc2 err=$err)"
  fi
  rm -rf "$dir"
}

test_stop_rejects_a_stale_file() {
  local name="a findings file left by an earlier round does not count as written"
  local dir rc=0
  dir="$(new_run ship-review)"
  echo old > "$dir/.context/ship-run/MOB-1/review-findings.md"
  sleep 1
  run_hook start "$(event "$dir" ship:ship-review agent-2)"
  run_hook stop "$(event "$dir" ship:ship-review agent-2)" || rc=$?
  if [ "$rc" -eq 2 ]; then log_pass "$name"; else log_fail "$name (rc=$rc)"; fi
  rm -rf "$dir"
}

test_stop_lets_the_second_stop_through() {
  local name="the second stop is let through, so a worker can never be held forever"
  local dir rc=0
  dir="$(new_run ship-review)"
  run_hook start "$(event "$dir" ship:ship-review agent-3)"
  run_hook stop "$(event "$dir" ship:ship-review agent-3 ',"stop_hook_active": true')" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$dir/.context/ship-run/MOB-1/worker-done-ship-review.txt" ]; then log_pass "$name"; else log_fail "$name (rc=$rc)"; fi
  rm -rf "$dir"
}

test_standalone_agents_are_left_alone() {
  local name="an agent the pipeline did not dispatch is never blocked"
  local dir rc=0
  dir="$(new_run ship-review)"
  run_hook start "$(event "$dir" ship:ship-review agent-4)"
  run_hook stop "$(event "$dir" ship:ship-review some-other-agent)" || rc=$?
  local rc_other=0
  run_hook stop "$(event "$dir" general-purpose agent-4)" || rc_other=$?
  if [ "$rc" -eq 0 ] && [ "$rc_other" -eq 0 ]; then log_pass "$name"; else log_fail "$name (rc=$rc other=$rc_other)"; fi
  rm -rf "$dir"
}

test_a_worker_that_changed_directory_is_still_marked_done() {
  local name="a worker whose cwd is a subdirectory at stop is still found and marked done"
  local dir rc=0
  dir="$(new_run ship-test-unit)"
  run_hook start "$(event "$dir" ship:ship-test-unit agent-9)"
  sleep 1
  mkdir -p "$dir/test/unit/deep"
  : > "$dir/.context/ship-run/MOB-1/generated-tests-unit.md"
  echo "Status: DONE" > "$dir/.context/ship-run/MOB-1/worker-status-unit.md"
  run_hook stop "$(event "$dir/test/unit/deep" ship:ship-test-unit agent-9)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$dir/.context/ship-run/MOB-1/worker-done-ship-test-unit.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
  rm -rf "$dir"
}

test_guard_denies_source_under_test() {
  local name="guard denies a test worker's edit to a Denylist path, allows its test file"
  local dir out_deny out_allow
  dir="$(new_run ship-test-unit)"
  printf '# Brief\n\n## Denylist\n\n- src/b.js\n\n## Source\n\n- src/b.js\n' > "$dir/.context/ship-run/MOB-1/test-brief-unit.md"
  run_hook start "$(event "$dir" ship:ship-test-unit agent-5)"
  out_deny="$(printf '%s' "$(event "$dir" ship:ship-test-unit agent-5 ",\"tool_input\":{\"file_path\":\"$dir/src/b.js\"}")" | bash "$HOOK" guard)"
  out_allow="$(printf '%s' "$(event "$dir" ship:ship-test-unit agent-5 ",\"tool_input\":{\"file_path\":\"$dir/tests/b.test.js\"}")" | bash "$HOOK" guard)"
  if printf '%s' "$out_deny" | grep -q '"permissionDecision":"deny"' && [ -z "$out_allow" ]; then
    log_pass "$name"
  else
    log_fail "$name (deny=$out_deny allow=$out_allow)"
  fi
  rm -rf "$dir"
}

test_guard_ignores_the_main_session() {
  local name="guard never touches an edit outside a Ship test worker"
  local dir out
  dir="$(mktemp -d)"
  out="$(printf '{"cwd":"%s","tool_input":{"file_path":"%s/src/b.js"}}' "$dir" "$dir" | bash "$HOOK" guard)"
  if [ -z "$out" ]; then log_pass "$name"; else log_fail "$name (out=$out)"; fi
  rm -rf "$dir"
}

test_start_records_the_worker
test_start_ignores_a_stale_run
test_stop_blocks_until_the_files_exist
test_a_blocked_stop_leaves_a_record
test_stop_rejects_a_stale_file
test_stop_lets_the_second_stop_through
test_standalone_agents_are_left_alone
test_a_worker_that_changed_directory_is_still_marked_done
test_guard_denies_source_under_test
test_guard_ignores_the_main_session

rm -f "$TMP_ERR"
echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
