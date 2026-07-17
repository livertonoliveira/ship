#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_FILE="$SCRIPT_DIR/../../patterns/worker-status.md"

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

test_pattern_file_exists() {
  local name="worker status pattern file exists"
  if [ ! -f "$PATTERN_FILE" ]; then
    log_fail "$name (not found at $PATTERN_FILE)"
    return
  fi
  log_pass "$name"
}

enum_section() {
  awk '
    /^## Enum/ { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$PATTERN_FILE"
}

test_enum_has_exactly_four_states() {
  local name="enum has exactly four states"
  local headings count
  headings="$(enum_section | grep -E '^### ' | sed -E 's/^### //')"
  count="$(printf '%s\n' "$headings" | grep -c .)"
  if [ "$count" -ne 4 ]; then
    log_fail "$name (expected 4 state headings, found $count: $headings)"
    return
  fi
  log_pass "$name"
}

test_enum_contains_expected_state_names_only() {
  local name="enum contains only the expected state names"
  local headings expected state
  headings="$(enum_section | grep -E '^### ' | sed -E 's/^### //')"
  expected="DONE
DONE_WITH_CONCERNS
NEEDS_CONTEXT
BLOCKED"
  while IFS= read -r state; do
    if ! printf '%s\n' "$expected" | grep -qxF "$state"; then
      log_fail "$name (unexpected heading: $state)"
      return
    fi
  done <<< "$headings"
  while IFS= read -r state; do
    if ! printf '%s\n' "$headings" | grep -qxF "$state"; then
      log_fail "$name (missing heading: $state)"
      return
    fi
  done <<< "$expected"
  log_pass "$name"
}

test_each_state_has_trigger_and_behavior() {
  local name="each state documents a trigger and a behavior"
  local state block
  for state in DONE DONE_WITH_CONCERNS NEEDS_CONTEXT BLOCKED; do
    block="$(awk -v h="### $state" '
      $0 == h { found=1; next }
      found && /^### / { exit }
      found { print }
    ' "$PATTERN_FILE")"
    if ! printf '%s' "$block" | grep -q '\*\*Trigger:\*\*'; then
      log_fail "$name (no Trigger for $state)"
      return
    fi
    if ! printf '%s' "$block" | grep -q '\*\*Behavior:\*\*'; then
      log_fail "$name (no Behavior for $state)"
      return
    fi
  done
  log_pass "$name"
}

test_fail_closed_rule_documented() {
  local name="fail-closed rule is documented"
  if ! grep -qi 'fail-closed' "$PATTERN_FILE"; then
    log_fail "$name (no case-insensitive mention of fail-closed)"
    return
  fi
  log_pass "$name"
}

test_missing_empty_out_of_enum_all_treated_as_blocked() {
  local name="missing, empty, and out-of-enum status values are all treated as blocked"
  local rule_line
  rule_line="$(grep -E '\*\*missing\*\*.*\*\*empty\*\*.*BLOCKED' "$PATTERN_FILE" || true)"
  if [ -z "$rule_line" ]; then
    log_fail "$name (no single rule line covering missing, empty, and BLOCKED)"
    return
  fi
  if ! printf '%s' "$rule_line" | grep -qi 'outside the four-value enum'; then
    log_fail "$name (rule line does not cover out-of-enum values)"
    return
  fi
  log_pass "$name"
}

test_edge_cases_each_resolve_to_blocked() {
  local name="edge cases for missing, empty, and out-of-enum values each resolve to blocked"
  local label
  for label in 'Missing' 'Out-of-enum' 'Empty'; do
    local block
    block="$(awk -v l="$label" '
      $0 ~ "^### Edge case [0-9]+ .* " l { found=1; next }
      found && /^### / { exit }
      found { print }
    ' "$PATTERN_FILE")"
    if [ -z "$block" ]; then
      log_fail "$name (no edge case section for $label)"
      return
    fi
    if ! printf '%s' "$block" | grep -q 'BLOCKED'; then
      log_fail "$name ($label edge case does not resolve to BLOCKED)"
      return
    fi
  done
  log_pass "$name"
}

test_pattern_file_exists
test_enum_has_exactly_four_states
test_enum_contains_expected_state_names_only
test_each_state_has_trigger_and_behavior
test_fail_closed_rule_documented
test_missing_empty_out_of_enum_all_treated_as_blocked
test_edge_cases_each_resolve_to_blocked

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
