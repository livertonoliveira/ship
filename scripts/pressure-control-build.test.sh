#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL_BUILD_SCRIPT="$REPO_ROOT/scripts/pressure-control-build.sh"
REAL_BUILD_JS="$REPO_ROOT/plugins/ship/scripts/build.js"
REAL_BUDGETS_JS="$REPO_ROOT/plugins/ship/scripts/budgets.js"

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
  mkdir -p "$dir/scripts" "$dir/src/skills/fixture-skill" "$dir/src/agents" "$dir/plugins/ship/scripts"
  cp "$CONTROL_BUILD_SCRIPT" "$dir/scripts/pressure-control-build.sh"
  chmod +x "$dir/scripts/pressure-control-build.sh"
  cp "$REAL_BUILD_JS" "$dir/plugins/ship/scripts/build.js"
  cp "$REAL_BUDGETS_JS" "$dir/plugins/ship/scripts/budgets.js"
}

write_fixture_skill() {
  local dir="$1"
  local out="$dir/src/skills/fixture-skill/SKILL.md"
  : > "$out"
  {
    printf '%s\n' "---"
    printf '%s\n' "name: fixture-skill"
    printf '%s\n' "description: fixture skill for control arm testing"
    printf '%s\n' "---"
    printf '\n'
    printf '%s\n' "# Fixture Skill"
    printf '\n'
    printf 'Intro text that always stays.\n'
    printf '\n'
    printf '%s\n' "## Guarded Instruction Block"
    printf '\n'
    printf 'Always double-check the widget calibration before shipping.\n'
    printf '\n'
    printf 'Extra guidance line inside the guarded block.\n'
    printf '\n'
    printf '%s\n' "## Trailing Section"
    printf '\n'
    printf 'Trailing content that always stays.\n'
  } >> "$out"
}

run_control_build() {
  local dir="$1" skill="$2" anchor="$3" out_dir="$4"
  (cd "$dir" && ./scripts/pressure-control-build.sh "$skill" "$anchor" "$out_dir")
}

run_control_build_expect_success() {
  local name="$1" precreate_out="${2:-}"
  local log status
  RCB_FAILED=0
  dir="$(mktemp -d)"
  out_dir="$dir/out"
  log="$(mktemp)"
  setup_fixture_repo "$dir"
  write_fixture_skill "$dir"
  if [ "$precreate_out" = "precreate" ]; then
    mkdir -p "$out_dir"
  fi

  status=0
  run_control_build "$dir" "fixture-skill" "Guarded Instruction Block" "$out_dir" >"$log" 2>&1 || status=$?

  if [ "$status" -ne 0 ]; then
    log_fail "$name (exit code was $status)"
    sed 's/^/    /' "$log"
    rm -f "$log"
    rm -rf "$dir"
    RCB_FAILED=1
    return
  fi

  rm -f "$log"
}

test_removes_declared_section_and_preserves_original() {
  local name="removes the declared section and preserves the original"
  local scratch expected_checksum after_checksum

  scratch="$(mktemp -d)"
  mkdir -p "$scratch/src/skills/fixture-skill"
  write_fixture_skill "$scratch"
  expected_checksum="$(shasum "$scratch/src/skills/fixture-skill/SKILL.md" | awk '{print $1}')"
  rm -rf "$scratch"

  run_control_build_expect_success "$name"
  if [ "$RCB_FAILED" -eq 1 ]; then
    return
  fi
  trap 'rm -rf "$dir"' RETURN

  if grep -q "widget calibration" "$out_dir/SKILL.md" 2>/dev/null; then
    log_fail "$name (built plugin still contains the guarded instruction)"
    return
  fi

  after_checksum="$(shasum "$dir/src/skills/fixture-skill/SKILL.md" | awk '{print $1}')"
  if [ "$expected_checksum" != "$after_checksum" ]; then
    log_fail "$name (original src SKILL.md was modified)"
    return
  fi

  log_pass "$name"
}

test_control_plugin_built_isolated() {
  local name="builds an isolated control plugin into an empty out-plugin-dir"

  run_control_build_expect_success "$name" precreate
  if [ "$RCB_FAILED" -eq 1 ]; then
    return
  fi
  trap 'rm -rf "$dir"' RETURN

  if [ ! -s "$out_dir/SKILL.md" ]; then
    log_fail "$name (out-plugin-dir/SKILL.md missing or empty)"
    return
  fi

  if grep -q "widget calibration" "$out_dir/SKILL.md"; then
    log_fail "$name (compiled SKILL.md still contains the guarded instruction)"
    return
  fi

  if ! grep -q "Trailing content that always stays" "$out_dir/SKILL.md"; then
    log_fail "$name (compiled SKILL.md lost unrelated content)"
    return
  fi

  log_pass "$name"
}

run_control_build_expect_failure() {
  local name="$1" expect_stderr_pattern="$2" expect_no_output="$3"
  shift 3
  local dir out_dir status stderr_output
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  out_dir="$dir/out"
  setup_fixture_repo "$dir"
  write_fixture_skill "$dir"

  status=0
  if [ "$expect_no_output" = "no-output" ]; then
    stderr_output="$(cd "$dir" && ./scripts/pressure-control-build.sh "$@" "$out_dir" 2>&1 1>/dev/null)" || status=$?
  else
    stderr_output="$(cd "$dir" && ./scripts/pressure-control-build.sh "$@" 2>&1 1>/dev/null)" || status=$?
  fi

  if [ "$status" -eq 0 ]; then
    log_fail "$name (exit code was 0, expected nonzero)"
    return
  fi

  if ! printf '%s' "$stderr_output" | grep -qi "$expect_stderr_pattern"; then
    log_fail "$name (stderr did not match '$expect_stderr_pattern': $stderr_output)"
    return
  fi

  if [ "$expect_no_output" = "no-output" ] && [ -e "$out_dir/SKILL.md" ]; then
    log_fail "$name (a plugin was produced despite the failure)"
    return
  fi

  log_pass "$name"
}

test_missing_anchor_fails_loudly() {
  local name="fails loudly with a nonzero exit and stderr message when the anchor is absent"
  run_control_build_expect_failure "$name" "anchor" "no-output" \
    "fixture-skill" "Nonexistent Anchor Text"
}

test_wrong_arg_count_fails_loudly() {
  local name="fails loudly with a nonzero exit and usage message when called with the wrong argument count"
  run_control_build_expect_failure "$name" "usage" "" "fixture-skill"
}

test_missing_skill_fails_loudly() {
  local name="fails loudly with a nonzero exit and stderr message when the skill does not exist"
  run_control_build_expect_failure "$name" "nonexistent-skill" "no-output" \
    "nonexistent-skill" "Guarded Instruction Block"
}

test_removes_declared_section_and_preserves_original
test_control_plugin_built_isolated
test_missing_anchor_fails_loudly
test_wrong_arg_count_fails_loudly
test_missing_skill_fails_loudly

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
