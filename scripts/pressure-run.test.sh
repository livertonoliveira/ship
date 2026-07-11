#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESSURE_RUN_SCRIPT="$REPO_ROOT/scripts/pressure-run.sh"
PRESSURE_CONTROL_BUILD_SCRIPT="$REPO_ROOT/scripts/pressure-control-build.sh"
PRESSURE_CORE_DIR="$REPO_ROOT/plugins/ship/scripts/pressure"
HOOKS_DIR="$REPO_ROOT/src/hooks"

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

setup_fixture_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/src/skills/fixture-skill" "$dir/src/hooks" "$dir/plugins/ship/scripts/pressure"
  cp "$PRESSURE_RUN_SCRIPT" "$dir/scripts/pressure-run.sh"
  chmod +x "$dir/scripts/pressure-run.sh"
  cp "$PRESSURE_CONTROL_BUILD_SCRIPT" "$dir/scripts/pressure-control-build.sh"
  chmod +x "$dir/scripts/pressure-control-build.sh"
  cp "$PRESSURE_CORE_DIR"/*.js "$dir/plugins/ship/scripts/pressure/"
  cp "$HOOKS_DIR/hygiene-scan.sh" "$dir/src/hooks/hygiene-scan.sh"
  cp "$HOOKS_DIR/plan-validate.sh" "$dir/src/hooks/plan-validate.sh"
  chmod +x "$dir/src/hooks/hygiene-scan.sh" "$dir/src/hooks/plan-validate.sh"
  : > "$dir/src/skills/fixture-skill/SKILL.md"
}

write_case() {
  local dir="$1" case_name="$2" skill_name="${3:-fixture-skill}"
  local case_dir="$dir/pressure/cases/$case_name"
  mkdir -p "$case_dir/arms/treatment/rep-01/code" "$case_dir/arms/control/rep-01/code"
  cat > "$case_dir/case.json" <<JSON
{
  "skill": "$skill_name",
  "input": "input.md",
  "arms": { "treatment": {}, "control": { "anchor": "Guarded Section" } },
  "assertions": ["noSpecIds"],
  "reps": 1,
  "expectedGate": "PASS"
}
JSON
  printf 'fixture input text\n' > "$case_dir/input.md"
}

test_replay_does_not_invoke_driver_and_prints_report() {
  local name="replay não invoca driver e imprime relatório"
  local status output

  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  setup_fixture_repo "$dir"
  write_case "$dir" "fixture-case"

  if ! command -v node >/dev/null 2>&1; then
    log_fail "$name (node not available to run replay in this environment)"
    return
  fi

  status=0
  output="$(cd "$dir" && PRESSURE_DRIVER=/nonexistent/should-not-be-invoked ./scripts/pressure-run.sh fixture-case --replay 2>&1)" || status=$?

  if [ "$status" -ne 0 ]; then
    log_fail "$name (exit code was $status: $output)"
    return
  fi

  if ! printf '%s' "$output" | grep -q "fixture-case"; then
    log_fail "$name (report did not mention case name: $output)"
    return
  fi

  if ! printf '%s' "$output" | grep -q "noSpecIds"; then
    log_fail "$name (report did not mention assertion: $output)"
    return
  fi

  log_pass "$name"
}

run_expect_failure() {
  local name="$1" expect_pattern="$2"
  shift 2
  local status output

  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  setup_fixture_repo "$dir"
  write_case "$dir" "fixture-case"

  status=0
  output="$(cd "$dir" && ./scripts/pressure-run.sh "$@" 2>&1 1>/dev/null)" || status=$?

  if [ "$status" -eq 0 ]; then
    log_fail "$name (exit code was 0, expected nonzero)"
    return
  fi

  if ! printf '%s' "$output" | grep -qi "$expect_pattern"; then
    log_fail "$name (stderr did not match '$expect_pattern': $output)"
    return
  fi

  log_pass "$name"
}

test_nonexistent_case_fails() {
  run_expect_failure "caso inexistente falha com stderr e exit != 0" "not found" "nonexistent-case" --replay
}

test_invalid_reps_fails() {
  run_expect_failure "--reps inválido falha com stderr e exit != 0" "reps" "fixture-case" --reps abc
}

test_nonexistent_skill_fails() {
  local name="skill inexistente falha com stderr e exit != 0"
  local status output

  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  setup_fixture_repo "$dir"
  write_case "$dir" "broken-case" "nonexistent-skill"

  status=0
  output="$(cd "$dir" && ./scripts/pressure-run.sh broken-case --replay 2>&1 1>/dev/null)" || status=$?

  if [ "$status" -eq 0 ]; then
    log_fail "$name (exit code was 0, expected nonzero)"
    return
  fi

  if ! printf '%s' "$output" | grep -qi "skill"; then
    log_fail "$name (stderr did not mention skill: $output)"
    return
  fi

  log_pass "$name"
}

test_replay_does_not_invoke_driver_and_prints_report
test_nonexistent_case_fails
test_invalid_reps_fails
test_nonexistent_skill_fails

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
