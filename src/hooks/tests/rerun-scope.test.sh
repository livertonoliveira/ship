#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RERUN_SCOPE_SCRIPT="$SCRIPT_DIR/../rerun-scope.sh"

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

phase_rerun_value() {
  local json="$1" phase="$2"
  printf '%s' "$json" | grep -oE "\"$phase\":\{\"rerun\":(true|false)" | sed -E 's/.*"rerun":(true|false)/\1/'
}

test_plain_src_file_triggers_perf_security_review() {
  local name="a changed non-test file under src/** triggers rerun:true for perf, security, and review"
  local tmp out
  tmp="$(mktemp -d)"
  printf 'src/runner.ts\n' > "$tmp/changed.txt"

  local rc=0
  out="$(bash "$RERUN_SCOPE_SCRIPT" "$tmp/changed.txt")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$tmp"
    return
  fi

  if [ "$(phase_rerun_value "$out" perf)" != "true" ]; then
    log_fail "$name (perf.rerun was not true: $out)"
    rm -rf "$tmp"
    return
  fi
  if [ "$(phase_rerun_value "$out" security)" != "true" ]; then
    log_fail "$name (security.rerun was not true: $out)"
    rm -rf "$tmp"
    return
  fi
  if [ "$(phase_rerun_value "$out" review)" != "true" ]; then
    log_fail "$name (review.rerun was not true: $out)"
    rm -rf "$tmp"
    return
  fi

  log_pass "$name"
  rm -rf "$tmp"
}

test_test_only_file_excludes_perf_but_not_security_review() {
  local name="a changed test file under src/** excludes perf but still triggers security and review"
  local tmp out
  tmp="$(mktemp -d)"
  printf 'src/runner.test.ts\n' > "$tmp/changed.txt"

  local rc=0
  out="$(bash "$RERUN_SCOPE_SCRIPT" "$tmp/changed.txt")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$tmp"
    return
  fi

  if [ "$(phase_rerun_value "$out" perf)" != "false" ]; then
    log_fail "$name (perf.rerun was not false: $out)"
    rm -rf "$tmp"
    return
  fi
  if [ "$(phase_rerun_value "$out" security)" != "true" ]; then
    log_fail "$name (security.rerun was not true: $out)"
    rm -rf "$tmp"
    return
  fi
  if [ "$(phase_rerun_value "$out" review)" != "true" ]; then
    log_fail "$name (review.rerun was not true: $out)"
    rm -rf "$tmp"
    return
  fi

  log_pass "$name"
  rm -rf "$tmp"
}

test_file_outside_src_and_lib_marks_out_of_scope() {
  local name="a changed file outside src/** and lib/** marks the top-level out_of_scope flag as true"
  local tmp out
  tmp="$(mktemp -d)"
  printf 'README.md\n' > "$tmp/changed.txt"

  local rc=0
  out="$(bash "$RERUN_SCOPE_SCRIPT" "$tmp/changed.txt")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$tmp"
    return
  fi

  if ! printf '%s' "$out" | grep -q '"out_of_scope":true'; then
    log_fail "$name (out_of_scope was not true: $out)"
    rm -rf "$tmp"
    return
  fi

  log_pass "$name"
  rm -rf "$tmp"
}

test_empty_input_marks_empty_and_no_phase_reruns() {
  local name="an empty changed-files list marks the top-level empty flag and no phase reports rerun:true"
  local tmp out
  tmp="$(mktemp -d)"
  : > "$tmp/changed.txt"

  local rc=0
  out="$(bash "$RERUN_SCOPE_SCRIPT" "$tmp/changed.txt")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$tmp"
    return
  fi

  if ! printf '%s' "$out" | grep -q '"empty":true'; then
    log_fail "$name (empty was not true: $out)"
    rm -rf "$tmp"
    return
  fi

  if printf '%s' "$out" | grep -q '"rerun":true'; then
    log_fail "$name (a phase reported rerun:true: $out)"
    rm -rf "$tmp"
    return
  fi

  log_pass "$name"
  rm -rf "$tmp"
}

test_empty_stdin_marks_empty_and_no_phase_reruns() {
  local name="empty stdin input marks the top-level empty flag and no phase reports rerun:true"
  local out
  local rc=0
  out="$(printf '' | bash "$RERUN_SCOPE_SCRIPT")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    return
  fi

  if ! printf '%s' "$out" | grep -q '"empty":true'; then
    log_fail "$name (empty was not true: $out)"
    return
  fi

  if printf '%s' "$out" | grep -q '"rerun":true'; then
    log_fail "$name (a phase reported rerun:true: $out)"
    return
  fi

  log_pass "$name"
}

test_missing_input_file_fails_with_usage_error() {
  local name="referencing a positional input file that does not exist fails with a non-zero exit code"
  local tmp
  tmp="$(mktemp -d)"

  local rc=0
  bash "$RERUN_SCOPE_SCRIPT" "$tmp/nonexistent.txt" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$tmp"
    return
  fi

  log_pass "$name"
  rm -rf "$tmp"
}

test_plain_src_file_triggers_perf_security_review
test_test_only_file_excludes_perf_but_not_security_review
test_file_outside_src_and_lib_marks_out_of_scope
test_empty_input_marks_empty_and_no_phase_reruns
test_empty_stdin_marks_empty_and_no_phase_reruns
test_missing_input_file_fails_with_usage_error

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
