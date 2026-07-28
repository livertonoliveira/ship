#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_VALIDATE_SCRIPT="$SCRIPT_DIR/../plan-validate.sh"

pass_count=0
fail_count=0

scenario_tag() {
  printf '@S''C-%s' "$1"
}

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

module_block() {
  local id="$1" title="$2" files="$3" depends_on="$4" scenarios="$5"
  printf '%s\n' "### ${id}: ${title}"
  printf '%s\n' "- Files: ${files}"
  printf '%s\n' "- Depends on: ${depends_on}"
  printf '%s\n' "- Scenarios: ${scenarios}"
  printf '\n'
}

contract_slot() {
  local scenario_id="$1" layer="$2" file="$3"
  printf '%s\n' "### ${scenario_id} -> ${layer} -> ${file}"
}

make_plan_fixture() {
  local dir="$1"
  shift
  local sections=("$@")
  local out="$dir/plan.md"
  : > "$out"
  local section
  for section in "${sections[@]}"; do
    printf '%s\n' "$section" >> "$out"
  done
  printf '%s' "$out"
}

run_validator() {
  local plan_file="$1" spec_file="${2:-}"
  local stderr_output rc=0
  if [ -n "$spec_file" ]; then
    stderr_output="$(bash "$PLAN_VALIDATE_SCRIPT" "$plan_file" --spec "$spec_file" 2>&1 1>/dev/null)" || rc=$?
  else
    stderr_output="$(bash "$PLAN_VALIDATE_SCRIPT" "$plan_file" 2>&1 1>/dev/null)" || rc=$?
  fi
  printf '%s\x1f%s' "$rc" "$stderr_output"
}

# The confrontation checks run inside the fixture dir so the on-disk existence
# test sees the fixture's tree, not the repo's.
run_validator_in() {
  local dir="$1" plan_file="$2" spec_file="$3"
  local stderr_output rc=0
  stderr_output="$(cd "$dir" && bash "$PLAN_VALIDATE_SCRIPT" "$plan_file" --spec "$spec_file" 2>&1 1>/dev/null)" || rc=$?
  printf '%s\x1f%s' "$rc" "$stderr_output"
}

assert_spec_check() {
  local name="$1" dir="$2" expected_rc="$3" expected_substring="$4"
  local result rc stderr_output
  result="$(run_validator_in "$dir" plan.md spec.md)"
  rc="${result%%$'\x1f'*}"
  stderr_output="${result#*$'\x1f'}"

  if [ "$rc" != "$expected_rc" ]; then
    log_fail "$name (exit code was $rc, expected $expected_rc; stderr: $stderr_output)"
    return
  fi
  if [ -n "$expected_substring" ] && ! printf '%s' "$stderr_output" | grep -qF "$expected_substring"; then
    log_fail "$name (stderr did not contain '$expected_substring': $stderr_output)"
    return
  fi
  log_pass "$name"
}

make_spec_fixture() {
  local dir="$1" files_block="$2" scenarios="$3"
  {
    printf '## Files\n%s\n\n## Scenarios\n%s\n' "$files_block" "$scenarios"
  } > "$dir/spec.md"
}

assert_exit_and_message() {
  local name="$1" plan_file="$2" expected_rc="$3" expected_substring="$4" require_empty_stderr="${5:-}"
  local result rc stderr_output
  result="$(run_validator "$plan_file")"
  rc="${result%%$'\x1f'*}"
  stderr_output="${result#*$'\x1f'}"

  if [ "$rc" != "$expected_rc" ]; then
    log_fail "$name (exit code was $rc, expected $expected_rc; stderr: $stderr_output)"
    return
  fi

  if [ -n "$expected_substring" ] && ! printf '%s' "$stderr_output" | grep -qF "$expected_substring"; then
    log_fail "$name (stderr did not contain '$expected_substring': $stderr_output)"
    return
  fi

  if [ -n "$require_empty_stderr" ] && [ -n "$stderr_output" ]; then
    log_fail "$name (stderr was not empty: $stderr_output)"
    return
  fi

  log_pass "$name"
}

test_spec_test_file_claimed_by_test_contract_passes() {
  local name="a test file the spec lists is accounted for by its Test Contract slot, not by a module"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src" && : > "$dir/src/a.ts"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak
- create \`src/a.test.ts\` — suite" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 0 ""
  rm -rf "$dir"
}

test_prose_in_divergences_does_not_account_for_a_file() {
  local name="a file merely mentioned in Map Divergences prose is not treated as diverged"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src" && : > "$dir/src/a.ts"
  # The shape a real planner produced: a "none" divergence section whose prose
  # names every spec file. Counting those as diverged made the check vacuous.
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" \
    "## Map Divergences" \
    "none — spec map (create \`src/b.ts\`) validated against the current tree" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak
- create \`src/b.ts\` — new" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 2 "plan-validate: arquivo do spec sem módulo"
  rm -rf "$dir"
}

test_empty_module_map_fails() {
  local name="a plan without any module headers fails with module map vazio"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: module map vazio"
  rm -rf "$dir"
}

test_file_overlap_fails() {
  local name="two modules declaring the same file fail with overlap de arquivos"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/shared.ts" "none" "$(scenario_tag 01)")" \
    "$(module_block "M2" "segundo" "src/shared.ts" "none" "$(scenario_tag 02)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")" \
    "$(contract_slot "$(scenario_tag 02)" unit "src/b.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: overlap de arquivos — src/shared.ts em M1, M2"
  rm -rf "$dir"
}

test_orphan_scenario_fails() {
  local name="a scenario without a Test Contract slot fails with cenário órfão"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 02)" unit "src/b.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: cenário órfão — $(scenario_tag 01) sem slot no Test Contract"
  rm -rf "$dir"
}

test_invalid_layer_fails() {
  local name="a Test Contract slot with an invalid layer fails with camada inválida"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" performance "src/a.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: camada inválida — $(scenario_tag 01) -> performance"
  rm -rf "$dir"
}

test_invalid_dependency_ref_fails() {
  local name="a module depending on an unknown module id fails with dependência inválida"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "M9" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: dependência inválida — M1 referencia M9 inexistente"
  rm -rf "$dir"
}

test_two_node_cycle_fails() {
  local name="two modules depending on each other fail with ciclo de dependência"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "M2" "$(scenario_tag 01)")" \
    "$(module_block "M2" "segundo" "src/b.ts" "M1" "$(scenario_tag 02)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")" \
    "$(contract_slot "$(scenario_tag 02)" unit "src/b.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: ciclo de dependência"
  rm -rf "$dir"
}

test_self_loop_cycle_fails() {
  local name="a module depending on itself fails with ciclo de dependência"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "M1" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: ciclo de dependência"
  rm -rf "$dir"
}

test_three_node_cycle_fails() {
  local name="three modules forming a dependency ring fail with ciclo de dependência"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "M2" "$(scenario_tag 01)")" \
    "$(module_block "M2" "segundo" "src/b.ts" "M3" "$(scenario_tag 02)")" \
    "$(module_block "M3" "terceiro" "src/c.ts" "M1" "$(scenario_tag 03)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")" \
    "$(contract_slot "$(scenario_tag 02)" unit "src/b.ts")" \
    "$(contract_slot "$(scenario_tag 03)" unit "src/c.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: ciclo de dependência"
  rm -rf "$dir"
}

test_multi_module_happy_path() {
  local name="a valid plan with multiple independent modules passes validation"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "$(module_block "M2" "segundo" "src/b.ts" "M1" "$(scenario_tag 02)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")" \
    "$(contract_slot "$(scenario_tag 02)" integration "src/b.ts")")"

  assert_exit_and_message "$name" "$plan" 0 ""
  rm -rf "$dir"
}

test_single_module_happy_path() {
  local name="a valid plan with a single module and no dependencies passes validation"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "unico" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" e2e "src/a.ts")")"

  assert_exit_and_message "$name" "$plan" 0 "" 1
  rm -rf "$dir"
}

test_overlap_regression_guard() {
  local name="a plan with a known file overlap must still be reported as invalid"
  local dir plan
  dir="$(mktemp -d)"
  plan="$(make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/shared.ts,src/a.ts" "none" "$(scenario_tag 01)")" \
    "$(module_block "M2" "segundo" "src/shared.ts,src/b.ts" "none" "$(scenario_tag 02)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.ts")" \
    "$(contract_slot "$(scenario_tag 02)" unit "src/b.ts")")"

  assert_exit_and_message "$name" "$plan" 2 "plan-validate: overlap de arquivos"
  rm -rf "$dir"
}

test_spec_scenario_without_module_fails() {
  local name="a spec scenario no module claims fails with cenário do spec sem módulo"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src" && : > "$dir/src/a.ts"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak" \
    "$(scenario_tag 01) @unit
$(scenario_tag 02) @unit"

  assert_spec_check "$name" "$dir" 2 "plan-validate: cenário do spec sem módulo — $(scenario_tag 02)"
  rm -rf "$dir"
}

test_spec_file_without_module_fails() {
  local name="a spec file no module claims fails with arquivo do spec sem módulo"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src" && : > "$dir/src/a.ts"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak
- create \`src/b.ts\` — new" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 2 "plan-validate: arquivo do spec sem módulo"
  rm -rf "$dir"
}

test_spec_file_logged_as_divergence_passes() {
  local name="a spec file logged under Map Divergences is accounted for"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src" && : > "$dir/src/a.ts"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" \
    "## Map Divergences" \
    "- src/b.ts — removido, sem sucessor" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak
- create \`src/b.ts\` — new" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 0 ""
  rm -rf "$dir"
}

test_missing_modify_target_fails() {
  local name="a path the spec marks modify that is absent on disk fails"
  local dir
  dir="$(mktemp -d)"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 2 "plan-validate: alvo 'modify' inexistente no repositório — src/a.ts"
  rm -rf "$dir"
}

test_create_target_absent_passes() {
  local name="a path the spec marks create needs no file on disk"
  local dir
  dir="$(mktemp -d)"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/b.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/b.test.ts")" >/dev/null
  make_spec_fixture "$dir" \
    "- create \`src/b.ts\` — new" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 0 ""
  rm -rf "$dir"
}

test_anchor_line_is_not_an_owned_file() {
  local name="an Ancora reference line is not treated as a file the plan must claim"
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/src" && : > "$dir/src/a.ts"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "$(contract_slot "$(scenario_tag 01)" unit "src/a.test.ts")" >/dev/null
  make_spec_fixture "$dir" \
    "- modify \`src/a.ts\` — tweak
- Âncora: siga o padrão de \`src/z.ts\` — reason" \
    "$(scenario_tag 01) @unit"

  assert_spec_check "$name" "$dir" 0 ""
  rm -rf "$dir"
}

test_empty_module_map_fails
test_file_overlap_fails
test_orphan_scenario_fails
test_invalid_layer_fails
test_invalid_dependency_ref_fails
test_two_node_cycle_fails
test_self_loop_cycle_fails
test_three_node_cycle_fails
test_multi_module_happy_path
test_single_module_happy_path
test_overlap_regression_guard
test_spec_scenario_without_module_fails
test_spec_file_without_module_fails
test_spec_file_logged_as_divergence_passes
test_missing_modify_target_fails
test_create_target_absent_passes
test_anchor_line_is_not_an_owned_file
test_spec_test_file_claimed_by_test_contract_passes
test_prose_in_divergences_does_not_account_for_a_file

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
