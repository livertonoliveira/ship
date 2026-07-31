#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/../spec-ids-scan.sh"

pass_count=0
fail_count=0

scenario_tag() {
  printf '@S''C-%s' "$1"
}

criterion_tag() {
  printf '@A''C''-%s' "$1"
}

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

make_tasks() {
  local dir="$1" body="$2"
  mkdir -p "$dir/ship/changes/f"
  printf '%s\n' "$body" > "$dir/ship/changes/f/tasks.md"
  printf '%s' "$dir/ship/changes/f/tasks.md"
}

scan_rc() {
  local f="$1" rc=0
  bash "$SCAN" "$f" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

hook_rc() {
  local f="$1" rc=0
  printf '{"tool_input":{"file_path":"%s"}}' "$f" | bash "$SCAN" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

test_one_id_two_behaviors_is_blocked() {
  local name="an id tagging two behaviorally distinct scenarios blocks the write"
  local dir file; dir="$(mktemp -d)"
  file="$(make_tasks "$dir" "  $(scenario_tag 08) $(criterion_tag 08) @unit
  Scenario: primeiro comportamento
    Quando a
    Entao b

  $(scenario_tag 08) $(criterion_tag 08) @unit
  Scenario: segundo comportamento
    Quando a
    Entao b")"
  if [ "$(scan_rc "$file")" = "2" ] && [ "$(hook_rc "$file")" = "2" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_distinct_ids_pass() {
  local name="distinct ids on distinct scenarios pass"
  local dir file; dir="$(mktemp -d)"
  file="$(make_tasks "$dir" "  $(scenario_tag 08) $(criterion_tag 08) @unit
  Scenario: primeiro comportamento
    Quando a
    Entao b

  $(scenario_tag 09) $(criterion_tag 08) @unit
  Scenario: segundo comportamento
    Quando a
    Entao b")"
  if [ "$(scan_rc "$file")" = "0" ] && [ "$(hook_rc "$file")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_the_same_scenario_repeated_verbatim_passes() {
  local name="the same scenario written twice verbatim is not two behaviors"
  local dir file; dir="$(mktemp -d)"
  file="$(make_tasks "$dir" "  $(scenario_tag 08) $(criterion_tag 08) @unit
  Scenario: identico
    Quando a
    Entao b

  $(scenario_tag 08) $(criterion_tag 08) @unit
  Scenario: identico
    Quando a
    Entao b")"
  if [ "$(scan_rc "$file")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_a_non_spec_file_is_ignored() {
  local name="a file that is not a spec artifact is left alone even when it names ids"
  local dir file rc; dir="$(mktemp -d)"
  file="$dir/notes.md"
  printf 'Falamos sobre %s hoje.\n' "$(scenario_tag 08)" > "$file"
  rc="$(scan_rc "$file")"
  if [ "$rc" != "2" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_scratch_dir_artifacts_are_ignored() {
  local name="the pipeline's own scratch copies are never re-gated"
  local dir file; dir="$(mktemp -d)"
  mkdir -p "$dir/.context/ship-run/T"
  file="$dir/.context/ship-run/T/spec.md"
  printf '  %s @unit\n  Scenario: um\n\n  %s @unit\n  Scenario: dois\n' \
    "$(scenario_tag 08)" "$(scenario_tag 08)" > "$file"
  if [ "$(scan_rc "$file")" != "2" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_a_missing_file_is_not_an_error() {
  local name="a write hook firing on a path that no longer exists exits clean"
  local rc
  rc="$(hook_rc "/tmp/definitely-not-here-$$.md")"
  if [ "$rc" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (exit $rc)"
  fi
}

test_one_id_two_behaviors_is_blocked
test_distinct_ids_pass
test_the_same_scenario_repeated_verbatim_passes
test_a_non_spec_file_is_ignored
test_scratch_dir_artifacts_are_ignored
test_a_missing_file_is_not_an_error

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
