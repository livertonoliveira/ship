#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${REPO_ROOT}/scripts/check-status-scripts-wired.sh"
CI_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

setup_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/src/skills/run" "$dir/plugins/ship/skills/run" "$dir/src/hooks"
  cp "$GUARD" "$dir/scripts/check-status-scripts-wired.sh"
  chmod +x "$dir/scripts/check-status-scripts-wired.sh"
}

write_src_skill() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/src/skills/run/SKILL.md"
}

write_compiled_skill() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/plugins/ship/skills/run/SKILL.md"
}

write_hook_files() {
  local dir="$1"
  shift
  local script
  for script in "$@"; do
    printf '#!/usr/bin/env bash\n' > "$dir/src/hooks/${script}"
    chmod +x "$dir/src/hooks/${script}"
  done
}

valid_src_body() {
  printf 'bash "@@ship/hooks/status-consolidate.sh" 1 phase-status-develop.md\n\nbash "@@ship/hooks/evidence-gate.sh" develop-touched-files.txt\n\nbash "@@ship/hooks/rerun-scope.sh" post-fix-changed-files.txt\n'
}

valid_compiled_body() {
  printf 'bash "${CLAUDE_SKILL_DIR}/hooks/status-consolidate.sh" 1 phase-status-develop.md\n\nbash "${CLAUDE_SKILL_DIR}/hooks/evidence-gate.sh" develop-touched-files.txt\n\nbash "${CLAUDE_SKILL_DIR}/hooks/rerun-scope.sh" post-fix-changed-files.txt\n'
}

body_without_script() {
  local prefix="$1" missing="$2"
  local script
  for script in status-consolidate.sh evidence-gate.sh rerun-scope.sh; do
    if [[ "$script" != "$missing" ]]; then
      printf 'bash "%s/%s" arg\n\n' "$prefix" "$script"
    fi
  done
}

test_guard_passes_on_happy_path() {
  local dir="$FIXTURE_DIR/pass"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(valid_src_body)"
  write_compiled_skill "$dir" "$(valid_compiled_body)"
  write_hook_files "$dir" status-consolidate.sh evidence-gate.sh rerun-scope.sh

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-status-scripts-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]] && grep -q "OK" <<<"$out"; then
    ok "guard exits 0 and prints OK when all three scripts are wired and present"
  else
    bad "guard did not pass on a clean fixture (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_when_invocation_missing() {
  local script="$1"
  local dir="$FIXTURE_DIR/missing-invocation-${script}"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(body_without_script '@@ship/hooks' "$script")"
  write_compiled_skill "$dir" "$(valid_compiled_body)"
  write_hook_files "$dir" status-consolidate.sh evidence-gate.sh rerun-scope.sh

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-status-scripts-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]] && grep -q "$script" <<<"$out"; then
    ok "guard exits non-zero and names ${script} when its invocation is missing"
  else
    bad "guard did not fail naming ${script} (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_when_hook_file_missing() {
  local dir="$FIXTURE_DIR/missing-hook-file"
  setup_fixture "$dir"
  write_src_skill "$dir" "$(valid_src_body)"
  write_compiled_skill "$dir" "$(valid_compiled_body)"
  write_hook_files "$dir" status-consolidate.sh evidence-gate.sh

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-status-scripts-wired.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]] && grep -q "rerun-scope.sh" <<<"$out" && grep -qi "not found" <<<"$out"; then
    ok "guard exits non-zero and names the missing rerun-scope.sh hook file"
  else
    bad "guard did not fail naming the missing hook file (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_wired_in_ci() {
  if [[ ! -f "$CI_WORKFLOW" ]]; then
    bad "CI workflow not found at $CI_WORKFLOW"
    return
  fi

  local job_block
  job_block="$(sed -n '/^  grep-guard:/,/^  [a-zA-Z0-9_-]\+:$/p' "$CI_WORKFLOW")"

  if grep -q "check-status-scripts-wired.sh" <<<"$job_block"; then
    ok "grep-guard job in ci.yml invokes check-status-scripts-wired.sh"
  else
    bad "grep-guard job in ci.yml does not invoke check-status-scripts-wired.sh"
  fi
}

echo "check-status-scripts-wired.sh — unit tests"
echo

test_guard_passes_on_happy_path
test_guard_fails_when_invocation_missing "status-consolidate.sh"
test_guard_fails_when_invocation_missing "evidence-gate.sh"
test_guard_fails_when_invocation_missing "rerun-scope.sh"
test_guard_fails_when_hook_file_missing
test_guard_wired_in_ci

echo
if [[ "$fail" -eq 0 ]]; then
  echo -e "\033[32mcheck-status-scripts-wired tests: PASS\033[0m"
else
  echo -e "\033[31mcheck-status-scripts-wired tests: FAIL\033[0m"
fi
exit "$fail"
