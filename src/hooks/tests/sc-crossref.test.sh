#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_CROSSREF_SCRIPT="$SCRIPT_DIR/../sc-crossref.sh"

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

scenario_id() {
  printf 'S''C''-%s' "$1"
}

criterion_id() {
  printf 'A''C''-%s' "$1"
}

index_line() {
  local scen="$1" crit="$2" layer="$3" title="$4"
  printf -- '- %s \xe2\x86\x92 %s \xc2\xb7 %s \xc2\xb7 %s' "$(scenario_id "$scen")" "$(criterion_id "$crit")" "$layer" "$title"
}

tag_line() {
  local scen="$1" crit="$2" layer="$3"
  printf '  @%s @%s @%s' "$(scenario_id "$scen")" "$(criterion_id "$crit")" "$layer"
}

write_index() {
  local f="$1"
  shift
  printf '%s\n' "$@" > "$f"
}

write_issue() {
  local f="$1"
  shift
  {
    printf '%s\n' "## Scenarios"
    printf '%s\n' ""
    printf '%s\n' '```gherkin'
    printf '%s\n' "$@"
    printf '%s\n' '```'
  } > "$f"
}

test_consistent_index_and_issues_pass() {
  local name="a consistent index and issue set with matching scenario/criterion tags reports clean and exits 0"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  write_index "$index" \
    "$(index_line 01 01 unit "nominal case")" \
    "$(index_line 02 02 integration "alt case")"

  write_issue "$issues/a.md" \
    "$(tag_line 01 01 unit)" \
    "  Scenario: nominal" \
    "" \
    "$(tag_line 02 02 integration)" \
    "  Scenario: alt"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "SC cross-reference — clean."; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_missing_id_is_reported() {
  local name="a scenario id present in the index with no Gherkin occurrence in any issue is reported as missing"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  write_index "$index" "$(index_line 03 01 unit "missing case")"
  write_issue "$issues/a.md" ""

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "missing: $(scenario_id 03)"; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_duplicate_id_is_reported() {
  local name="a scenario id present in the Gherkin of two issues is reported as duplicate"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  write_index "$index" "$(index_line 05 01 unit "dup case")"
  write_issue "$issues/a.md" "$(tag_line 05 01 unit)" "  Scenario: dup"
  write_issue "$issues/b.md" "$(tag_line 05 01 unit)" "  Scenario: dup2"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "duplicate: $(scenario_id 05)"; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_duplicate_id_across_three_issues_is_reported_twice() {
  local name="a scenario id present in the Gherkin of three issues is reported as duplicate for both the second and third occurrence"
  local dir index issues out rc=0 dup_count
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  write_index "$index" "$(index_line 06 01 unit "triple dup case")"
  write_issue "$issues/a.md" "$(tag_line 06 01 unit)" "  Scenario: dup a"
  write_issue "$issues/b.md" "$(tag_line 06 01 unit)" "  Scenario: dup b"
  write_issue "$issues/c.md" "$(tag_line 06 01 unit)" "  Scenario: dup c"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  dup_count="$(printf '%s\n' "$out" | grep -cF "duplicate: $(scenario_id 06)")"

  if [ "$dup_count" -ne 2 ]; then
    log_fail "$name (expected 2 duplicate lines, got $dup_count: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_orphan_id_is_reported() {
  local name="a scenario id present in an issue's Gherkin but absent from the index is reported as orphan"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  : > "$index"
  write_issue "$issues/a.md" "$(tag_line 09 02 unit)" "  Scenario: orphan"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "orphan: $(scenario_id 09)"; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_mismatched_criterion_is_reported() {
  local name="a scenario id whose criterion differs between the index and the issue Gherkin is reported as mismatch"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  write_index "$index" "$(index_line 02 01 unit "mismatch case")"
  write_issue "$issues/a.md" "$(tag_line 02 04 unit)" "  Scenario: mismatch"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "mismatch: $(scenario_id 02)"; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_scenario_depth_none_is_clean() {
  local name="an empty index and issues with no Scenarios block reports clean and exits 0"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues"

  : > "$index"
  {
    printf '%s\n' "# No scenarios here"
    printf '%s\n' "just prose"
  } > "$issues/a.md"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "SC cross-reference — clean."; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_nested_issue_file_is_found() {
  local name="an issue file nested two levels deep under the issues directory is discovered and reported as present"
  local dir index issues out rc=0
  dir="$(mktemp -d)"
  index="$dir/index.txt"
  issues="$dir/issues"
  mkdir -p "$issues/group"

  write_index "$index" "$(index_line 07 01 unit "nested case")"
  write_issue "$issues/group/nested.md" "$(tag_line 07 01 unit)" "  Scenario: nested"

  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$index" --issues "$issues")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc: $out)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$out" | grep -qF "SC cross-reference — clean."; then
    log_fail "$name (unexpected output: $out)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_missing_args_usage_fails() {
  local name="running without required flags prints usage and exits non-zero"
  local rc=0
  local stderr_output
  stderr_output="$(bash "$SC_CROSSREF_SCRIPT" 2>&1 >/dev/null)" || rc=$?

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

test_consistent_index_and_issues_pass
test_missing_id_is_reported
test_duplicate_id_is_reported
test_duplicate_id_across_three_issues_is_reported_twice
test_orphan_id_is_reported
test_mismatched_criterion_is_reported
test_scenario_depth_none_is_clean
test_nested_issue_file_is_found
test_missing_args_usage_fails


# --- AC coverage -------------------------------------------------------------
# An AC no scenario covers is invisible to the test worker: the brief filters
# scenarios by layer tag, so an untagged criterion reaches it nowhere and ships
# untested. Observed live — two workers had to add the missing assertions
# themselves after noticing the gap.

ac_fixture() {
  local dir="$1" acs="$2" index="$3"
  mkdir -p "$dir/issues"
  { printf '## Requirements\n'; printf '%s\n' "$acs"; } > "$dir/proposal.md"
  printf '%s\n' "$index" > "$dir/index.md"
  printf '## Scenarios\n@SC-01 @AC-01 @unit\nScenario: nominal\n' > "$dir/issues/t1.md"
}

test_ac_without_scenario_is_flagged() {
  local name="an AC with no scenario covering it is reported as uncovered"
  local dir out rc=0
  dir="$(mktemp -d)"
  ac_fixture "$dir" "- AC-01: soma
- AC-02: subtrai" "- SC-01 -> AC-01 · unit · soma"
  out="$(bash "$SC_CROSSREF_SCRIPT" --index "$dir/index.md" --issues "$dir/issues" --proposal "$dir/proposal.md")" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^uncovered: AC-02'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_static_ac_is_exempt() {
  local name="an AC marked (static) needs no scenario"
  local dir rc=0
  dir="$(mktemp -d)"
  ac_fixture "$dir" "- AC-01: soma
- AC-02 (static): arquivo abaixo de 30 linhas" "- SC-01 -> AC-01 · unit · soma"
  bash "$SC_CROSSREF_SCRIPT" --index "$dir/index.md" --issues "$dir/issues" --proposal "$dir/proposal.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"

  # Without the exemption the gate rejects legitimate non-behavioral criteria,
  # and a gate that cries wolf gets switched off.
  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — a (static) AC was demanded a scenario)"
  fi
}

test_ac_check_is_skipped_without_an_index() {
  local name="depth=none (no scenario index) skips the AC check entirely"
  local dir rc=0
  dir="$(mktemp -d)"
  mkdir -p "$dir/issues"
  printf '## Requirements\n- AC-01: soma\n- AC-02: subtrai\n' > "$dir/proposal.md"
  : > "$dir/index.md"
  bash "$SC_CROSSREF_SCRIPT" --index "$dir/index.md" --issues "$dir/issues" --proposal "$dir/proposal.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"

  # At depth=none the absence of scenarios is the configuration, not an omission.
  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — depth=none was treated as missing coverage)"
  fi
}

test_ac_check_is_opt_in() {
  local name="omitting --proposal leaves the original behavior untouched"
  local dir rc=0
  dir="$(mktemp -d)"
  ac_fixture "$dir" "- AC-01: soma
- AC-02: subtrai" "- SC-01 -> AC-01 · unit · soma"
  bash "$SC_CROSSREF_SCRIPT" --index "$dir/index.md" --issues "$dir/issues" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — the AC check ran without being asked for)"
  fi
}

test_fully_covered_spec_is_clean() {
  local name="a spec whose every AC has a scenario passes"
  local dir rc=0
  dir="$(mktemp -d)"
  mkdir -p "$dir/issues"
  printf '## Requirements\n- AC-01: soma\n- AC-02: subtrai\n' > "$dir/proposal.md"
  printf -- '- SC-01 -> AC-01 · unit · soma\n- SC-02 -> AC-02 · unit · subtrai\n' > "$dir/index.md"
  printf '## Scenarios\n@SC-01 @AC-01 @unit\nScenario: soma\n@SC-02 @AC-02 @unit\nScenario: subtrai\n' > "$dir/issues/t1.md"
  bash "$SC_CROSSREF_SCRIPT" --index "$dir/index.md" --issues "$dir/issues" --proposal "$dir/proposal.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
}

test_depth_has_only_none_and_full() {
  local name="Scenario Depth offers only none and full — the ambiguous middle is gone"
  local root init spec
  root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  init="$root/src/skills/init/SKILL.md"
  spec="$root/src/skills/spec/SKILL.md"
  # `light` was defined differently in the two files (1/AC vs nominal+error/AC),
  # so it could not be enforced consistently. Removed rather than reconciled.
  if ! grep -q 'light' "$init" && ! grep -q '`light`' "$spec" \
    && grep -q 'AC-NN (static)' "$spec"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_ac_without_scenario_is_flagged
test_static_ac_is_exempt
test_ac_check_is_skipped_without_an_index
test_ac_check_is_opt_in
test_fully_covered_spec_is_clean
test_depth_has_only_none_and_full

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
