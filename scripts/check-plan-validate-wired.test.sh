#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${REPO_ROOT}/scripts/check-plan-validate-wired.sh"
CI_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

setup_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/src/skills/run" "$dir/plugins/ship/skills/run" \
    "$dir/src/hooks" "$dir/plugins/ship/hooks"
  cp "$GUARD" "$dir/scripts/check-plan-validate-wired.sh"
  chmod +x "$dir/scripts/check-plan-validate-wired.sh"
}

write_skills() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/src/skills/run/SKILL.md"
  printf '%s\n' "$body" > "$dir/plugins/ship/skills/run/SKILL.md"
}

write_pipelines() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/src/hooks/pipeline.sh"
  printf '%s\n' "$body" > "$dir/plugins/ship/hooks/pipeline.sh"
}

driver_skill_body() {
  printf 'Run: bash "@@ship/hooks/pipeline.sh" next <task-id> and do what it says.'
}

pipeline_body_validate_before_develop() {
  printf 'bash "$HOOK_DIR/plan-validate.sh" "$SCRATCH/plan.md"\ncmd_dispatch "$SCRATCH" dev Skill ship:develop sonnet\nnext_body_add "- Skill ship:develop (forked)"\n'
}

pipeline_body_validate_after_develop() {
  printf 'next_body_add "- Skill ship:develop (forked)"\nbash "$HOOK_DIR/plan-validate.sh" "$SCRATCH/plan.md"\n'
}

pipeline_body_without_validate() {
  printf 'next_body_add "- Skill ship:develop (forked)"\n'
}

run_guard() {
  local dir="$1"
  set +e
  GUARD_OUT="$(cd "$dir" && ./scripts/check-plan-validate-wired.sh 2>&1)"
  GUARD_STATUS=$?
  set -e
}

test_guard_passes_on_happy_path() {
  local dir="$FIXTURE_DIR/pass"
  setup_fixture "$dir"
  write_skills "$dir" "$(driver_skill_body)"
  write_pipelines "$dir" "$(pipeline_body_validate_before_develop)"
  run_guard "$dir"

  if [[ "$GUARD_STATUS" -eq 0 ]] && grep -q "OK" <<<"$GUARD_OUT"; then
    ok "guard exits 0 when the SKILL drives pipeline.sh and validation precedes the develop dispatch"
  else
    bad "guard did not pass on a clean fixture (status=$GUARD_STATUS)"
    printf '%s\n' "$GUARD_OUT" | sed 's/^/    /'
  fi
}

test_guard_fails_when_pipeline_lacks_validate() {
  local dir="$FIXTURE_DIR/no-validate"
  setup_fixture "$dir"
  write_skills "$dir" "$(driver_skill_body)"
  write_pipelines "$dir" "$(pipeline_body_without_validate)"
  run_guard "$dir"

  if [[ "$GUARD_STATUS" -eq 1 ]] && grep -q "VIOLATION" <<<"$GUARD_OUT" && grep -q "plan-validate.sh" <<<"$GUARD_OUT"; then
    ok "guard exits 1 when neither the SKILL nor pipeline.sh invokes plan-validate.sh"
  else
    bad "guard did not fail on a pipeline without plan-validate (status=$GUARD_STATUS)"
    printf '%s\n' "$GUARD_OUT" | sed 's/^/    /'
  fi
}

test_guard_fails_when_validate_after_develop_dispatch() {
  local dir="$FIXTURE_DIR/wrong-order"
  setup_fixture "$dir"
  write_skills "$dir" "$(driver_skill_body)"
  write_pipelines "$dir" "$(pipeline_body_validate_after_develop)"
  run_guard "$dir"

  if [[ "$GUARD_STATUS" -eq 1 ]] && grep -qi "not before" <<<"$GUARD_OUT"; then
    ok "guard exits 1 when validation follows the ship:develop dispatch in the state machine"
  else
    bad "guard did not fail on wrong ordering (status=$GUARD_STATUS)"
    printf '%s\n' "$GUARD_OUT" | sed 's/^/    /'
  fi
}

test_guard_fails_when_skill_lacks_pipeline_reference() {
  local dir="$FIXTURE_DIR/skill-unwired"
  setup_fixture "$dir"
  write_skills "$dir" "This skill mentions no hooks at all."
  write_pipelines "$dir" "$(pipeline_body_validate_before_develop)"
  run_guard "$dir"

  if [[ "$GUARD_STATUS" -eq 1 ]] && grep -q "VIOLATION" <<<"$GUARD_OUT" && grep -q "SKILL.md" <<<"$GUARD_OUT"; then
    ok "guard exits 1 when the SKILL neither invokes plan-validate.sh nor drives pipeline.sh"
  else
    bad "guard did not fail on an unwired SKILL (status=$GUARD_STATUS)"
    printf '%s\n' "$GUARD_OUT" | sed 's/^/    /'
  fi
}

test_build_produces_no_drift_in_plugins_ship() {
  local plugin_dir="${REPO_ROOT}/plugins/ship"

  if [[ ! -f "$plugin_dir/package.json" ]]; then
    bad "plugins/ship/package.json not found, cannot run build-drift check"
    return
  fi

  local before after build_status backup_dir
  before="$(git -C "$REPO_ROOT" status --porcelain -- plugins/ship)"

  backup_dir="$(mktemp -d)"
  cp -R "$plugin_dir" "$backup_dir/ship-backup"

  restore_plugins_ship() {
    rm -rf "$plugin_dir"
    cp -R "$backup_dir/ship-backup" "$plugin_dir"
    rm -rf "$backup_dir"
  }
  trap restore_plugins_ship RETURN

  build_status=0
  (cd "$plugin_dir" && npm run build >/dev/null 2>&1) || build_status=$?

  if [[ "$build_status" -ne 0 ]]; then
    bad "npm run build failed in plugins/ship"
    return
  fi

  after="$(git -C "$REPO_ROOT" status --porcelain -- plugins/ship)"

  if [[ "$before" != "$after" ]]; then
    bad "npm run build produced unexpected drift in plugins/ship relative to pre-build state"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/    /' || true
    return
  fi

  if git -C "$REPO_ROOT" diff --exit-code -- plugins/ship >/dev/null 2>&1; then
    ok "npm run build produces no drift in plugins/ship (git diff --exit-code is clean)"
  else
    ok "npm run build leaves plugins/ship in the same state as before the run (pre-existing uncommitted changes unaffected)"
  fi
}

test_compiled_run_skill_within_line_budget() {
  local compiled_skill="${REPO_ROOT}/plugins/ship/skills/run/SKILL.md"
  local max_lines=780

  if [[ ! -f "$compiled_skill" ]]; then
    bad "${compiled_skill} not found"
    return
  fi

  local line_count
  line_count=$(wc -l < "$compiled_skill" | tr -d '[:space:]')

  if [[ "$line_count" -le "$max_lines" ]]; then
    ok "plugins/ship/skills/run/SKILL.md has ${line_count} lines, within budget of ${max_lines}"
  else
    bad "plugins/ship/skills/run/SKILL.md has ${line_count} lines, exceeding budget of ${max_lines}"
  fi
}

test_guard_wired_in_ci() {
  if [[ ! -f "$CI_WORKFLOW" ]]; then
    bad "CI workflow not found at $CI_WORKFLOW"
    return
  fi

  local job_block
  job_block="$(sed -n '/^  grep-guard:/,/^  [a-zA-Z0-9_-]\+:$/p' "$CI_WORKFLOW")"

  if grep -q "check-plan-validate-wired.sh" <<<"$job_block"; then
    ok "grep-guard job in ci.yml invokes check-plan-validate-wired.sh"
  else
    bad "grep-guard job in ci.yml does not invoke check-plan-validate-wired.sh"
  fi
}

echo "check-plan-validate-wired.sh — unit tests"
echo

test_guard_passes_on_happy_path
test_guard_fails_when_pipeline_lacks_validate
test_guard_fails_when_validate_after_develop_dispatch
test_guard_fails_when_skill_lacks_pipeline_reference
test_build_produces_no_drift_in_plugins_ship
test_compiled_run_skill_within_line_budget
test_guard_wired_in_ci

echo
if [[ "$fail" -eq 0 ]]; then
  echo -e "\033[32mcheck-plan-validate-wired tests: PASS\033[0m"
else
  echo -e "\033[31mcheck-plan-validate-wired tests: FAIL\033[0m"
fi
exit "$fail"
