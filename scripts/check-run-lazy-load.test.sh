#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${REPO_ROOT}/scripts/check-run-lazy-load.sh"
CI_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

setup_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/src/skills/run" "$dir/plugins/ship/skills/run"
  cp "$GUARD" "$dir/scripts/check-run-lazy-load.sh"
  chmod +x "$dir/scripts/check-run-lazy-load.sh"
}

write_src_skill() {
  local dir="$1" body="$2"
  printf '%s\n' "$body" > "$dir/src/skills/run/SKILL.md"
}

write_compiled_skill() {
  local dir="$1" lines="$2"
  seq 1 "$lines" | sed 's/^/line /' > "$dir/plugins/ship/skills/run/SKILL.md"
}

test_guard_passes_when_converted() {
  local dir="$FIXTURE_DIR/pass"
  setup_fixture "$dir"
  write_src_skill "$dir" "Use \${CLAUDE_SKILL_DIR}/patterns/foo.md for details."
  write_compiled_skill "$dir" 780

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-run-lazy-load.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]] && grep -q "OK" <<<"$out"; then
    ok "guard exits 0 and prints OK when converted and within budget"
  else
    bad "guard did not pass on a clean fixture (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_on_inline_ref() {
  local dir="$FIXTURE_DIR/inline-ref"
  setup_fixture "$dir"
  write_src_skill "$dir" "See @ship/patterns/foo.md for details."
  write_compiled_skill "$dir" 780

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-run-lazy-load.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 1 ]] && grep -q "VIOLATION" <<<"$out" && grep -qi "inline" <<<"$out"; then
    ok "guard exits 1 and reports the violation when an inline ref is reintroduced"
  else
    bad "guard did not fail on a reintroduced inline @ship/patterns/ ref (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

test_guard_fails_on_budget_exceeded() {
  local dir="$FIXTURE_DIR/budget-exceeded"
  setup_fixture "$dir"
  write_src_skill "$dir" "Use \${CLAUDE_SKILL_DIR}/patterns/foo.md for details."
  write_compiled_skill "$dir" 781

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/check-run-lazy-load.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 1 ]] && grep -q "VIOLATION" <<<"$out" && grep -qi "exceeding budget" <<<"$out"; then
    ok "guard exits 1 and reports the violation when the compiled skill exceeds its line budget"
  else
    bad "guard did not fail when the compiled skill exceeds the line budget (status=$status)"
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

  if grep -q "check-run-lazy-load.sh" <<<"$job_block"; then
    ok "grep-guard job in ci.yml invokes check-run-lazy-load.sh"
  else
    bad "grep-guard job in ci.yml does not invoke check-run-lazy-load.sh"
  fi
}

echo "check-run-lazy-load.sh — unit tests"
echo

test_guard_passes_when_converted
test_guard_fails_on_inline_ref
test_guard_fails_on_budget_exceeded
test_guard_wired_in_ci

echo
if [[ "$fail" -eq 0 ]]; then
  echo -e "\033[32mcheck-run-lazy-load tests: PASS\033[0m"
else
  echo -e "\033[31mcheck-run-lazy-load tests: FAIL\033[0m"
fi
exit "$fail"
