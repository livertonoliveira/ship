#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_EXEC="$SCRIPT_DIR/../test-exec.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A repo whose suite is a script: the gate's verdict must come from what the
# script printed and from the contract files, never from a guess.
setup_repo() {
  local dir="$1"
  mkdir -p "$dir/scratch" "$dir/test"
  printf '# Config\n\n- Artifact language: en\n- Test Framework: ./suite.sh\n' > "$dir/config.md"
  printf '{"scripts":{}}\n' > "$dir/package.json"
  touch "$dir/scratch/static-exec-done.txt"
}

# Measured live on a 27-node graph: every oracle-backed spec guarded itself with
# `existsSync(fixture) ? describe : describe.skip`, no workspace had the
# fixture, and the gate reported 24 precision tests green that never ran.
test_skip_in_contract_file_fails_the_gate() {
  local name="a skip construct in a contract test file fails the test gate even when the runner is green"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  printf '#!/usr/bin/env bash\necho "PASS test/a.spec.ts"\necho "Tests:       7 skipped, 3 passed, 10 total"\nexit 0\n' > "$d/suite.sh"
  chmod +x "$d/suite.sh"
  printf 'const ok = false;\nconst describeParity = ok ? describe : describe.skip;\ndescribeParity("x", () => {});\n' > "$d/test/a.spec.ts"
  printf -- '- test/a.spec.ts (unit)\n' > "$d/scratch/generated-tests.md"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 1 ] \
    && grep -q '## Skipped cases in contract test files' "$d/scratch/test-failures.md" \
    && grep -q 'test/a.spec.ts:2' "$d/scratch/test-failures.md" \
    && grep -q '7 case(s) reported skipped' "$d/scratch/test-failures.md" \
    && grep -q '| fail |' "$d/scratch/phase-status-test.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc report=$(tr '\n' ' ' < "$d/scratch/test-failures.md" 2>/dev/null))"
  fi
  rm -rf "$d"
}

test_skip_outside_the_contract_is_only_reported() {
  local name="a pre-existing suite's skips are reported in the summary but do not fail a green contract"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  printf '#!/usr/bin/env bash\necho "Tests:       2 skipped, 8 passed, 10 total"\nexit 0\n' > "$d/suite.sh"
  chmod +x "$d/suite.sh"
  printf 'it("runs", () => {});\n' > "$d/test/a.spec.ts"
  printf -- '- test/a.spec.ts (unit)\n' > "$d/scratch/generated-tests.md"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] \
    && ! grep -q '## Skipped cases' "$d/scratch/test-failures.md" \
    && grep -q '2 case(s) reported skipped' "$d/scratch/test-failures.md" \
    && grep -q '| pass |' "$d/scratch/phase-status-test.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc report=$(tr '\n' ' ' < "$d/scratch/test-failures.md" 2>/dev/null))"
  fi
  rm -rf "$d"
}

test_pytest_skip_marker_is_caught() {
  local name="a pytest skip marker in a contract file is caught like a jest one"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  printf '#!/usr/bin/env bash\necho "3 passed, 1 skipped"\nexit 0\n' > "$d/suite.sh"
  chmod +x "$d/suite.sh"
  printf 'import pytest\n\n@pytest.mark.skipif(True, reason="no data")\ndef test_x():\n    pass\n' > "$d/test/test_a.py"
  printf -- '- test/test_a.py (unit)\n' > "$d/scratch/generated-tests.md"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'test/test_a.py:3' "$d/scratch/test-failures.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc report=$(tr '\n' ' ' < "$d/scratch/test-failures.md" 2>/dev/null))"
  fi
  rm -rf "$d"
}

# Measured live: pnpm 11 refused the repo's build scripts, `pnpm typecheck`
# died inside `pnpm install`, and the node spent a remediation round on a
# typecheck that had compiled nothing.
test_static_that_never_ran_is_an_environment_stop() {
  local name="--static-only exits 4 with an environment report when the tool never started, and writes no exits file"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  printf -- '- Typecheck: ./tc.sh\n' >> "$d/config.md"
  printf '#!/usr/bin/env bash\necho "[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts: sweph@2.10.3"\necho "[ERROR] Command failed with exit code 1: pnpm install"\nexit 1\n' > "$d/tc.sh"
  chmod +x "$d/tc.sh"
  rm -f "$d/scratch/static-exec-done.txt"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 4 ] \
    && [ ! -e "$d/scratch/static-exits.txt" ] \
    && grep -q '## Environment: the checks could not run' "$d/scratch/static-failures.md" \
    && grep -q 'ERR_PNPM_IGNORED_BUILDS' "$d/scratch/static-failures.md" \
    && grep -q 'environment: checks could not run' "$d/scratch/phase-status-static.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc files=$(ls "$d/scratch" | tr '\n' ' ') report=$(tr '\n' ' ' < "$d/scratch/static-failures.md" 2>/dev/null))"
  fi
  rm -rf "$d"
}

test_a_real_typecheck_error_is_still_a_failure() {
  local name="a genuine compiler error keeps exit 1 and the exits file — only a tool that never ran is an environment stop"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  printf -- '- Typecheck: ./tc.sh\n' >> "$d/config.md"
  printf '#!/usr/bin/env bash\necho "src/a.ts(1,1): error TS2304: Cannot find name foo"\nexit 2\n' > "$d/tc.sh"
  chmod +x "$d/tc.sh"
  rm -f "$d/scratch/static-exec-done.txt"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 1 ] && grep -qx 'typecheck=2' "$d/scratch/static-exits.txt"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc exits=$(cat "$d/scratch/static-exits.txt" 2>/dev/null | tr '\n' ' '))"
  fi
  rm -rf "$d"
}

test_runner_that_never_ran_is_an_environment_stop() {
  local name="a suite whose runner never started exits 4 with the environment report instead of a contentless failure"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  printf '#!/usr/bin/env bash\necho "sh: jest: command not found"\nexit 127\n' > "$d/suite.sh"
  chmod +x "$d/suite.sh"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 4 ] \
    && grep -q '### Test runner did not run' "$d/scratch/test-failures.md" \
    && grep -q 'environment: checks could not run' "$d/scratch/phase-status-test.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc report=$(tr '\n' ' ' < "$d/scratch/test-failures.md" 2>/dev/null))"
  fi
  rm -rf "$d"
}

# Measured live (2026-10-13, 2 of 2 nodes): develop changed a constructor, the
# committed specs kept the old signature, the author left them "for the test
# phase", and every node paid a remediation round for one missing edit.
test_static_check_names_existing_tests_the_change_broke() {
  local name="--static-check lists committed test files the typecheck now rejects, and only those"
  local d; d="$(mktemp -d)"
  setup_repo "$d"
  (cd "$d" && git init -q && git config user.email t@t && git config user.name T \
    && mkdir -p test/unit src && : > test/unit/old.spec.ts && : > src/a.ts \
    && git add -A && git commit -qm base) >/dev/null 2>&1
  : > "$d/test/unit/new.spec.ts"
  printf -- '- Typecheck: ./tc.sh\n' >> "$d/config.md"
  printf '#!/usr/bin/env bash\necho "test/unit/old.spec.ts(66,13): error TS2554: Expected 10 arguments, but got 9."\necho "test/unit/new.spec.ts(3,1): error TS2304: Cannot find name x"\necho "src/a.ts(1,1): error TS2304: Cannot find name y"\nexit 2\n' > "$d/tc.sh"
  chmod +x "$d/tc.sh"
  rm -f "$d/scratch/static-exec-done.txt"
  local out rc=0
  out="$(cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-check 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 1 ] \
    && printf '%s' "$out" | grep -q '## Existing test files broken by this change' \
    && printf '%s' "$out" | grep -qx -- '- test/unit/old.spec.ts' \
    && ! printf '%s' "$out" | grep -qx -- '- test/unit/new.spec.ts' \
    && ! printf '%s' "$out" | grep -qx -- '- src/a.ts' \
    && printf '%s' "$out" | grep -qx 'broken-existing-tests=1'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$(printf '%s' "$out" | tr '\n' ' '))"
  fi
  rm -rf "$d"
}

test_skip_in_contract_file_fails_the_gate
test_skip_outside_the_contract_is_only_reported
test_pytest_skip_marker_is_caught
test_static_that_never_ran_is_an_environment_stop
test_a_real_typecheck_error_is_still_a_failure
test_runner_that_never_ran_is_an_environment_stop
test_static_check_names_existing_tests_the_change_broke

echo ""
echo "${pass_count} passed, ${fail_count} failed"
[ "$fail_count" -eq 0 ]
