#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/../worker-status-gate.sh"

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

test_valid_enum_value_exits_zero() {
  local state="$1"
  local name="valid enum value $state exits 0"
  local dir f rc=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  f="$dir/phase-status-develop.md"
  printf 'Status: %s\n' "$state" > "$f"

  bash "$GATE_SCRIPT" "$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    return
  fi

  log_pass "$name"
}

test_invalid_status_exits_nonzero() {
  local value="$1" label="$2"
  local name="invalid status ($label) exits non-zero"
  local dir f rc=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  f="$dir/phase-status-develop.md"
  printf 'Status: %s\n' "$value" > "$f"

  bash "$GATE_SCRIPT" "$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi

  log_pass "$name"
}

test_missing_status_field_exits_nonzero() {
  local name="missing Status field exits non-zero"
  local dir f rc=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  f="$dir/phase-status-develop.md"
  printf 'Notes: nothing relevant\n' > "$f"

  bash "$GATE_SCRIPT" "$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi

  log_pass "$name"
}

test_conflicting_status_lines_exit_nonzero() {
  local name="multiple conflicting Status lines exit non-zero"
  local dir f rc=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  f="$dir/phase-status-develop.md"
  printf 'Status: DONE\nsome text\nStatus: BLOCKED\n' > "$f"

  bash "$GATE_SCRIPT" "$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi

  log_pass "$name"
}

test_missing_file_exits_nonzero_with_stderr() {
  local name="missing status file exits non-zero and mentions the path in stderr"
  local dir missing rc=0 stderr_output
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  missing="$dir/phase-status-absent.md"

  stderr_output="$(bash "$GATE_SCRIPT" "$missing" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi
  if ! printf '%s' "$stderr_output" | grep -qF "$missing"; then
    log_fail "$name (stderr did not mention missing file: $stderr_output)"
    return
  fi

  log_pass "$name"
}

test_valid_enum_value_exits_zero "DONE"
test_valid_enum_value_exits_zero "DONE_WITH_CONCERNS"
test_valid_enum_value_exits_zero "NEEDS_CONTEXT"
test_valid_enum_value_exits_zero "BLOCKED"

test_invalid_status_exits_nonzero "done" "lowercase"
test_invalid_status_exits_nonzero "DONEE" "typo"
test_invalid_status_exits_nonzero "PASS" "out of enum"
test_invalid_status_exits_nonzero "" "empty value"

test_missing_status_field_exits_nonzero
test_conflicting_status_lines_exit_nonzero
test_missing_file_exits_nonzero_with_stderr

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
