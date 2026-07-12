#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDS_CLARIFICATION_SCAN_SCRIPT="$SCRIPT_DIR/../needs-clarification-scan.sh"

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

marker_line() {
  local category="$1" topic="$2"
  printf '[NEEDS CLARIFICATION: %s: %s]' "$category" "$topic"
}

write_doc() {
  local f="$1"
  shift
  printf '%s\n' "$@" > "$f"
}

test_functional_scope_marker_fails() {
  local name="a document containing a functional-scope NEEDS CLARIFICATION marker exits 2"
  local dir doc rc=0
  dir="$(mktemp -d)"
  doc="$dir/spec.md"

  write_doc "$doc" \
    "# Spec" \
    "" \
    "Some prose here." \
    "$(marker_line functional-scope "what happens on retry")"

  bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "$doc" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 2 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_low_impact_only_warns() {
  local name="a document whose only marker category is terminology exits 1"
  local dir doc rc=0
  dir="$(mktemp -d)"
  doc="$dir/spec.md"

  write_doc "$doc" \
    "# Spec" \
    "" \
    "$(marker_line terminology "naming for the widget")"

  bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "$doc" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 1 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_no_markers_is_clean() {
  local name="a document with no NEEDS CLARIFICATION markers exits 0"
  local dir doc out rc=0
  dir="$(mktemp -d)"
  doc="$dir/spec.md"

  write_doc "$doc" \
    "# Spec" \
    "" \
    "Nothing to clarify here."

  out="$(bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "$doc")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "NEEDS CLARIFICATION scan — clean."; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_category_severity_mapping() {
  local category code
  local pairs=(
    "functional-scope|2"
    "data-model|2"
    "ux-flow|1"
    "non-functional|1"
    "integrations|1"
    "edge-cases|1"
    "tradeoffs|1"
    "terminology|1"
    "completion-signals|1"
  )
  local pair
  for pair in "${pairs[@]}"; do
    IFS='|' read -r category code <<< "$pair"
    local name="a document whose only marker category is $category exits $code"
    local dir doc rc=0
    dir="$(mktemp -d)"
    doc="$dir/spec.md"

    write_doc "$doc" \
      "# Spec" \
      "" \
      "$(marker_line "$category" "some topic")"

    bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "$doc" >/dev/null 2>&1 || rc=$?

    if [ "$rc" -ne "$code" ]; then
      log_fail "$name (exit code was $rc)"
      rm -rf "$dir"
      continue
    fi

    log_pass "$name"
    rm -rf "$dir"
  done
}

test_marker_without_category_separator_warns() {
  local name="a marker with no inner category separator falls back to warn and exits 1"
  local dir doc rc=0
  dir="$(mktemp -d)"
  doc="$dir/spec.md"

  write_doc "$doc" \
    "# Spec" \
    "" \
    "[NEEDS CLARIFICATION: no colon here]"

  bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "$doc" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 1 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_missing_args_usage_fails() {
  local name="running without a target argument prints usage and exits non-zero"
  local rc=0
  local stderr_output
  stderr_output="$(bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi

  if ! printf '%s' "$stderr_output" | grep -qF "usage:"; then
    log_fail "$name (stderr did not contain usage: $stderr_output)"
    return
  fi

  log_pass "$name"
}

test_invalid_target_usage_fails() {
  local name="running with a nonexistent path prints usage and exits non-zero"
  local rc=0
  local stderr_output
  stderr_output="$(bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "/nonexistent/path/does-not-exist" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    return
  fi

  if ! printf '%s' "$stderr_output" | grep -qF "usage:"; then
    log_fail "$name (stderr did not contain usage: $stderr_output)"
    return
  fi

  log_pass "$name"
}

test_directory_scan_finds_nested_markers() {
  local name="a directory containing a nested file with a functional-scope marker exits 2"
  local dir docs rc=0
  dir="$(mktemp -d)"
  docs="$dir/docs"
  mkdir -p "$docs/group"

  write_doc "$docs/group/nested.md" \
    "# Nested" \
    "$(marker_line functional-scope "nested retry behavior")"

  bash "$NEEDS_CLARIFICATION_SCAN_SCRIPT" "$docs" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 2 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_functional_scope_marker_fails
test_low_impact_only_warns
test_no_markers_is_clean
test_category_severity_mapping
test_marker_without_category_separator_warns
test_missing_args_usage_fails
test_invalid_target_usage_fails
test_directory_scan_finds_nested_markers

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
