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

make_scaffold_fixture() {
  local dir="$1"
  shift
  local out="$dir/plan-scaffold.md"
  : > "$out"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$out"
  done
}

make_plan_fixture() {
  local dir="$1"
  shift
  local out="$dir/plan.md"
  : > "$out"
  local section
  for section in "$@"; do
    printf '%s\n' "$section" >> "$out"
  done
}

seed_fixture_files() {
  local dir="$1"
  mkdir -p "$dir/src"
  : > "$dir/src/a.ts"
  : > "$dir/src/b.ts"
}

build_scenario_title_fixture() {
  local dir="$1" inject="$2"
  make_scaffold_fixture "$dir" \
    "## File Inventory" \
    "- src/a.ts (create) -> M?" \
    "## Test Contract" \
    "### S1 $(scenario_tag 01) (base) -> unit -> TBD"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "### S1 $(scenario_tag 01) (base ${inject}) -> unit -> src/a.test.ts"
}

build_module_title_fixture() {
  local dir="$1" inject="$2"
  make_scaffold_fixture "$dir" \
    "## File Inventory" \
    "- src/a.ts (create) -> M?" \
    "## Test Contract" \
    "### S1 $(scenario_tag 01) (base) -> unit -> TBD"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro ${inject}" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "## Test Contract" \
    "### S1 $(scenario_tag 01) (base) -> unit -> src/a.test.ts"
}

build_depends_annotation_fixture() {
  local dir="$1" inject="$2"
  make_scaffold_fixture "$dir" \
    "## File Inventory" \
    "- src/a.ts (create) -> M?" \
    "- src/b.ts (create) -> M?" \
    "## Test Contract" \
    "### S1 $(scenario_tag 01) (base) -> unit -> TBD"
  make_plan_fixture "$dir" \
    "## Modules" \
    "$(module_block "M1" "primeiro" "src/a.ts" "none" "$(scenario_tag 01)")" \
    "$(module_block "M2" "segundo" "src/b.ts" "M1 (${inject})" "")" \
    "## Test Contract" \
    "### S1 $(scenario_tag 01) (base) -> unit -> src/a.test.ts"
}

run_case_rc() {
  local dir="$1" rc=0
  (cd "$dir" && bash "$PLAN_VALIDATE_SCRIPT" plan.md >/dev/null 2>&1) || rc=$?
  printf '%s' "$rc"
}

run_case() {
  local dir="$1" rc=0 stderr_output
  stderr_output="$(cd "$dir" && bash "$PLAN_VALIDATE_SCRIPT" plan.md 2>&1 1>/dev/null)" || rc=$?
  printf '%s\x1f%s' "$rc" "$stderr_output"
}

CHARS=(
  '>'
  '>='
  '<'
  '<='
  '->'
  '|'
  '#'
  ':'
  ','
  '('
  ')'
  '['
  ']'
  '%'
  '"'
  "'"
  '`'
  '...'
  '—'
  'ç'
  'ã'
)

COMBOS=(
  'p95 > 200ms'
  'estado pending -> running'
  'retorna 4xx|5xx'
  'RSS > 15%'
)

PLACEMENTS=('scenario_title' 'module_title' 'depends_annotation')

build_fixture_for() {
  local placement="$1" dir="$2" inject="$3"
  case "$placement" in
    'scenario_title') build_scenario_title_fixture "$dir" "$inject" ;;
    'module_title') build_module_title_fixture "$dir" "$inject" ;;
    'depends_annotation') build_depends_annotation_fixture "$dir" "$inject" ;;
  esac
}

matrix_signature() {
  local placement label dir rc
  for placement in "${PLACEMENTS[@]}"; do
    for label in "${CHARS[@]}" "${COMBOS[@]}"; do
      dir="$(mktemp -d)"
      seed_fixture_files "$dir"
      build_fixture_for "$placement" "$dir" "$label"
      rc="$(run_case_rc "$dir")"
      printf '%s\t%s\t%s\n' "$placement" "$label" "$rc"
      rm -rf "$dir"
    done
  done
}

expected_rc_for() {
  local placement="$1" label="$2"
  case "$placement" in
    'scenario_title')
      case "$label" in
        '->') printf '2' ;;
        'estado pending -> running') printf '2' ;;
        *) printf '0' ;;
      esac
      ;;
    'depends_annotation')
      case "$label" in
        ',') printf '2' ;;
        *) printf '0' ;;
      esac
      ;;
    *)
      printf '0'
      ;;
  esac
}

run_matrix_assertions() {
  local results="$1"
  local placement label rc expected name
  while IFS=$'\t' read -r placement label rc; do
    [ -n "$placement" ] || continue
    expected="$(expected_rc_for "$placement" "$label")"
    name="fuzz matrix — ${placement} carrying '${label}' exits ${expected}"
    if [ "$rc" = "$expected" ]; then
      log_pass "$name"
    else
      log_fail "$name (got exit $rc, expected $expected)"
    fi
  done <<< "$results"
}

test_regression_pin_paren_and_gt() {
  local placement label dir rc name
  for placement in "${PLACEMENTS[@]}"; do
    for label in '(' '>'; do
      dir="$(mktemp -d)"
      seed_fixture_files "$dir"
      build_fixture_for "$placement" "$dir" "$label"
      rc="$(run_case_rc "$dir")"
      name="regression pin — '${label}' stays accepted in ${placement}"
      if [ "$rc" = "0" ]; then
        log_pass "$name"
      else
        log_fail "$name (got exit $rc)"
      fi
      rm -rf "$dir"
    done
  done
}

test_literal_arrow_in_scenario_title_is_declared_unsupported() {
  local dir result rc stderr_output
  dir="$(mktemp -d)"
  seed_fixture_files "$dir"
  build_scenario_title_fixture "$dir" '->'
  result="$(run_case "$dir")"
  rc="${result%%$'\x1f'*}"
  stderr_output="${result#*$'\x1f'}"
  local name="a literal '->' inside a scenario title is declared unsupported, not silently accepted"
  if [ "$rc" = "2" ] && [ -n "$stderr_output" ]; then
    log_pass "$name"
  else
    log_fail "$name (exit $rc, stderr: $stderr_output)"
  fi
  rm -rf "$dir"
}

test_full_matrix_is_deterministic() {
  local run1 run2
  run1="$(matrix_signature)"
  run2="$(matrix_signature)"
  local name="the full fixture matrix produces byte-identical stdout across two consecutive runs"
  if [ "$run1" = "$run2" ]; then
    log_pass "$name"
  else
    log_fail "$name (outputs differed between the two runs)"
  fi
  MATRIX_RESULTS="$run1"
}

test_discovered_by_run_hook_tests_glob() {
  local self_name found
  self_name="$(basename "${BASH_SOURCE[0]}")"
  found="$(find "$SCRIPT_DIR" -maxdepth 1 -name "*.test.sh" -print0 | xargs -0 -n1 basename | sort)"
  local name="scripts/run-hook-tests.sh's glob over src/hooks/tests/*.test.sh discovers this file"
  if printf '%s\n' "$found" | grep -qxF "$self_name"; then
    log_pass "$name"
  else
    log_fail "$name (discovered: $found)"
  fi
}

MATRIX_RESULTS=""
test_full_matrix_is_deterministic
run_matrix_assertions "$MATRIX_RESULTS"
test_regression_pin_paren_and_gt
test_literal_arrow_in_scenario_title_is_declared_unsupported
test_discovered_by_run_hook_tests_glob

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
