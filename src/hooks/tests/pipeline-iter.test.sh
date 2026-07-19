#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_SCRIPT="$SCRIPT_DIR/../pipeline.sh"

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

test_first_call_starts_at_one() {
  local name="first call against a fresh scratch dir returns count=1"
  local dir out rc=0
  dir="$(mktemp -d)"

  out="$(bash "$PIPELINE_SCRIPT" iter "$dir" fix)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    return
  fi
  if [ "$out" != "count=1" ]; then
    log_fail "$name (got: $out)"
    return
  fi
  log_pass "$name"
}

test_counter_persists_and_increments_across_calls() {
  local name="counter persists across separate invocations and increments"
  local dir rc=0
  dir="$(mktemp -d)"

  bash "$PIPELINE_SCRIPT" iter "$dir" fix >/dev/null
  bash "$PIPELINE_SCRIPT" iter "$dir" fix >/dev/null
  local out
  out="$(bash "$PIPELINE_SCRIPT" iter "$dir" fix)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    return
  fi
  if [ "$out" != "count=3" ]; then
    log_fail "$name (got: $out)"
    return
  fi
  log_pass "$name"
}

test_distinct_counter_names_are_independent() {
  local name="distinct counter names track independent counts in the same scratch dir"
  local dir out_fix out_test rc=0
  dir="$(mktemp -d)"

  bash "$PIPELINE_SCRIPT" iter "$dir" fix >/dev/null
  bash "$PIPELINE_SCRIPT" iter "$dir" fix >/dev/null
  out_fix="$(bash "$PIPELINE_SCRIPT" iter "$dir" fix)" || rc=$?
  out_test="$(bash "$PIPELINE_SCRIPT" iter "$dir" test-fix)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    return
  fi
  if [ "$out_fix" != "count=3" ] || [ "$out_test" != "count=1" ]; then
    log_fail "$name (got fix=$out_fix test-fix=$out_test)"
    return
  fi
  log_pass "$name"
}

test_exceeding_max_exits_2() {
  local name="exceeding --max exits 2 while still reporting the count"
  local dir out rc=0
  dir="$(mktemp -d)"

  bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3 >/dev/null
  bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3 >/dev/null
  bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3 >/dev/null
  out="$(bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 2 ]; then
    log_fail "$name (exit code was $rc, expected 2)"
    return
  fi
  if [ "$out" != "count=4" ]; then
    log_fail "$name (got: $out)"
    return
  fi
  log_pass "$name"
}

test_at_max_still_exits_0() {
  local name="reaching exactly --max still exits 0"
  local dir rc=0
  dir="$(mktemp -d)"

  bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3 >/dev/null
  bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3 >/dev/null
  bash "$PIPELINE_SCRIPT" iter "$dir" fix --max 3 >/dev/null || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc, expected 0)"
    return
  fi
  log_pass "$name"
}

test_invalid_counter_name_rejected() {
  local name="a counter name with path separators is rejected"
  local dir rc=0
  dir="$(mktemp -d)"

  bash "$PIPELINE_SCRIPT" iter "$dir" "../escape" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi
  log_pass "$name"
}

setup_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
    mkdir -p ship
    printf -- '- Language: bash\n' > ship/config.md
  )
}

test_fresh_init_resets_counters() {
  local name="pipeline.sh init --mode fresh removes prior iteration counters"
  local dir task rc=0
  dir="$(mktemp -d)"
  task="iterresettask"
  setup_repo "$dir"

  (
    cd "$dir"
    bash "$PIPELINE_SCRIPT" init "$task" --mode fresh >/dev/null
    bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix >/dev/null
    bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix >/dev/null
    bash "$PIPELINE_SCRIPT" init "$task" --mode fresh >/dev/null

    out="$(bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix)"
    [ "$out" = "count=1" ] || exit 1
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (counter was not reset by a fresh re-init)"
    return
  fi
  log_pass "$name"
}

test_resume_init_resets_counters() {
  local name="pipeline.sh init --mode resume also removes prior iteration counters (no stale-count abort)"
  local dir task rc=0
  dir="$(mktemp -d)"
  task="iterresumetask"
  setup_repo "$dir"

  (
    cd "$dir"
    bash "$PIPELINE_SCRIPT" init "$task" --mode fresh >/dev/null
    bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix --max 3 >/dev/null
    bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix --max 3 >/dev/null
    bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix --max 3 >/dev/null
    bash "$PIPELINE_SCRIPT" init "$task" --mode resume >/dev/null

    local out ec=0
    out="$(bash "$PIPELINE_SCRIPT" iter ".context/ship-run/$task" fix --max 3)" || ec=$?
    [ "$ec" -eq 0 ] || exit 1
    [ "$out" = "count=1" ] || exit 1
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (resume inherited a stale count and would abort prematurely)"
    return
  fi
  log_pass "$name"
}

test_first_call_starts_at_one
test_counter_persists_and_increments_across_calls
test_distinct_counter_names_are_independent
test_exceeding_max_exits_2
test_at_max_still_exits_0
test_invalid_counter_name_rejected
test_fresh_init_resets_counters
test_resume_init_resets_counters

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
