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

HASH="$(printf '\043')"
HEADING_PLAN="${HASH}${HASH}${HASH} 1.95. PHASE: Plan Validation"
HEADING_DEV="${HASH}${HASH}${HASH} 2. PHASE: Development"

setup_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/src/skills/run" "$dir/plugins/ship/skills/run"
  cp "$GUARD" "$dir/scripts/check-plan-validate-wired.sh"
  chmod +x "$dir/scripts/check-plan-validate-wired.sh"
}

write_src_skill() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/src/skills/run/SKILL.md"
}

write_compiled_skill() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/plugins/ship/skills/run/SKILL.md"
}

valid_src_body() {
  printf '%s\n\n```bash\nbash "@@ship/hooks/plan-validate.sh" .context/ship-run/<task-id>/plan.md\n```\n\n%s\n\nDo the thing.' \
    "$HEADING_PLAN" "$HEADING_DEV"
}

valid_compiled_body() {
  printf '%s\n\n```bash\nbash "${CLAUDE_SKILL_DIR}/hooks/plan-validate.sh" .context/ship-run/<task-id>/plan.md\n```\n\n%s\n\nDo the thing.' \
    "$HEADING_PLAN" "$HEADING_DEV"
}

body_without_invocation() {
  printf '%s\n\nNothing here.\n\n%s\n\nDo the thing.' "$HEADING_PLAN" "$HEADING_DEV"
}

body_invocation_after_development() {
  printf '%s\n\nDo the thing.\n\n%s\n\n```bash\nbash "@@ship/hooks/plan-validate.sh" .context/ship-run/<task-id>/plan.md\n```' \
    "$HEADING_DEV" "$HEADING_PLAN"
}

test_guard_passes_on_happy_path() {
  local dir="$FIXTURE_DIR/pass"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(valid_src_body)"
  write_compiled_skill "$dir" "$(valid_compiled_body)"

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-plan-validate-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]] && grep -q "OK" <<<"$out"; then
    ok "guard exits 0 and prints OK when both files invoke plan-validate before Development"
  else
    bad "guard did not pass on a clean fixture (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_when_src_missing_invocation() {
  local dir="$FIXTURE_DIR/src-missing"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(body_without_invocation)"
  write_compiled_skill "$dir" "$(valid_compiled_body)"

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-plan-validate-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 1 ]] && grep -q "VIOLATION" <<<"$out" && grep -q "src/skills/run/SKILL.md" <<<"$out"; then
    ok "guard exits 1 and names src/skills/run/SKILL.md when invocation is missing there"
  else
    bad "guard did not fail naming src/skills/run/SKILL.md (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_when_compiled_missing_invocation() {
  local dir="$FIXTURE_DIR/compiled-missing"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(valid_src_body)"
  write_compiled_skill "$dir" "$(body_without_invocation)"

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-plan-validate-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 1 ]] && grep -q "VIOLATION" <<<"$out" && grep -q "plugins/ship/skills/run/SKILL.md" <<<"$out"; then
    ok "guard exits 1 and names plugins/ship/skills/run/SKILL.md when invocation is missing there"
  else
    bad "guard did not fail naming plugins/ship/skills/run/SKILL.md (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_when_invocation_after_development_heading() {
  local dir="$FIXTURE_DIR/wrong-order"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(body_invocation_after_development)"
  write_compiled_skill "$dir" "$(valid_compiled_body)"

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-plan-validate-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 1 ]] && grep -q "VIOLATION" <<<"$out" && grep -qi "not before" <<<"$out"; then
    ok "guard exits 1 when invocation is placed after the Development heading"
  else
    bad "guard did not fail when invocation follows the Development heading (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
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
test_guard_fails_when_src_missing_invocation
test_guard_fails_when_compiled_missing_invocation
test_guard_fails_when_invocation_after_development_heading
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
