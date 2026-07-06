#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSOLIDATE_SCRIPT="$SCRIPT_DIR/../status-consolidate.sh"

PLACEHOLDER="$(printf '%s' '#' '<RUN>' | tr -d '\n')"

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

make_row() {
  local phase="$1" marker="$2"
  printf '| %s | %s | 2026-07-06 | 3 | pass | 0 | 0 | 0 | 0 | - |\n' "$phase" "$marker"
}

run_marker() {
  local n="$1"
  printf '%s%s' '#' "$n"
}

test_consolidates_two_scratch_files_in_order() {
  local name="consolidates two scratch files in the given order"
  local dir develop perf out rc=0
  dir="$(mktemp -d)"
  develop="$dir/phase-status-develop.md"
  perf="$dir/phase-status-perf.md"
  make_row "develop" "$PLACEHOLDER" > "$develop"
  make_row "perf" "$PLACEHOLDER" > "$perf"

  out="$(bash "$CONSOLIDATE_SCRIPT" 1 "$develop" "$perf")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  local first second
  first="$(printf '%s\n' "$out" | sed -n '1p')"
  second="$(printf '%s\n' "$out" | sed -n '2p')"

  if [[ "$first" != *"develop"* ]]; then
    log_fail "$name (first line was not develop: $first)"
    rm -rf "$dir"
    return
  fi
  if [[ "$second" != *"perf"* ]]; then
    log_fail "$name (second line was not perf: $second)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_byte_for_byte_determinism() {
  local name="byte-for-byte determinism across repeated runs"
  local dir a b out1 out2
  dir="$(mktemp -d)"
  a="$dir/phase-status-develop.md"
  b="$dir/phase-status-perf.md"
  make_row "develop" "$PLACEHOLDER" > "$a"
  make_row "perf" "$PLACEHOLDER" > "$b"

  out1="$(bash "$CONSOLIDATE_SCRIPT" 4 "$a" "$b")"
  out2="$(bash "$CONSOLIDATE_SCRIPT" 4 "$a" "$b")"

  if [ "$out1" != "$out2" ]; then
    log_fail "$name (outputs differed)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_empty_scratch_is_ignored() {
  local name="empty scratch is ignored (exit 0, no stdout contribution)"
  local dir empty out rc=0
  dir="$(mktemp -d)"
  empty="$dir/phase-status-empty.md"
  : > "$empty"

  out="$(bash "$CONSOLIDATE_SCRIPT" 1 "$empty")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi
  if [ -n "$out" ]; then
    log_fail "$name (expected empty stdout, got: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_missing_scratch_fails() {
  local name="missing scratch fails with non-zero exit and stderr mentions the path"
  local dir missing rc=0 stderr_output
  dir="$(mktemp -d)"
  missing="$dir/phase-status-absent.md"

  stderr_output="$(bash "$CONSOLIDATE_SCRIPT" 1 "$missing" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi
  if ! printf '%s' "$stderr_output" | grep -qF "$missing"; then
    log_fail "$name (stderr did not mention missing file: $stderr_output)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_replaces_placeholder_with_run_number() {
  local name="replaces placeholder with the run number"
  local dir scratch out expected_marker
  dir="$(mktemp -d)"
  scratch="$dir/phase-status-develop.md"
  make_row "develop" "$PLACEHOLDER" > "$scratch"

  out="$(bash "$CONSOLIDATE_SCRIPT" 2 "$scratch")"
  expected_marker="$(run_marker 2)"

  if [[ "$out" != *"$expected_marker"* ]]; then
    log_fail "$name (expected $expected_marker in output: $out)"
    rm -rf "$dir"
    return
  fi
  if [[ "$out" == *"$PLACEHOLDER"* ]]; then
    log_fail "$name (placeholder still present: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_line_without_placeholder_passes_through_unchanged() {
  local name="line without placeholder passes through unchanged"
  local dir scratch input out existing_marker
  dir="$(mktemp -d)"
  scratch="$dir/phase-status-develop.md"
  existing_marker="$(run_marker 1)"
  input="$(make_row "develop" "$existing_marker")"
  printf '%s' "$input" > "$scratch"

  out="$(bash "$CONSOLIDATE_SCRIPT" 3 "$scratch")"

  if [ "$out" != "$input" ]; then
    log_fail "$name (expected identical line: got $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_consolidates_two_scratch_files_in_order
test_byte_for_byte_determinism
test_empty_scratch_is_ignored
test_missing_scratch_fails
test_replaces_placeholder_with_run_number
test_line_without_placeholder_passes_through_unchanged

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
