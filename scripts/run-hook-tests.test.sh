#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/run-hook-tests.sh"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; }

setup_fixture() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/src/hooks/tests"
  cp "$RUNNER" "$dir/scripts/run-hook-tests.sh"
  chmod +x "$dir/scripts/run-hook-tests.sh"
}

write_green_test() {
  local path="$1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$path"
  chmod +x "$path"
}

write_red_test() {
  local path="$1"
  printf '#!/usr/bin/env bash\necho "boom"\nexit 1\n' > "$path"
  chmod +x "$path"
}

test_runner_passes_all_green_tests() {
  local dir="$FIXTURE_DIR/all-green"
  setup_fixture "$dir"
  write_green_test "$dir/src/hooks/tests/a.test.sh"
  write_green_test "$dir/src/hooks/tests/b.test.sh"

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/run-hook-tests.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 ]] && grep -q "2 passed, 0 failed" <<<"$out"; then
    ok "runner exits 0 and reports 2 passed, 0 failed when all hook tests are green"
  else
    bad "runner did not report a clean summary on all-green fixture (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
  fi
}

test_runner_fails_and_names_failed_file() {
  local dir="$FIXTURE_DIR/one-red"
  setup_fixture "$dir"
  write_green_test "$dir/src/hooks/tests/a.test.sh"
  write_red_test "$dir/src/hooks/tests/b.test.sh"

  local out status
  set +e
  out="$(cd "$dir" && ./scripts/run-hook-tests.sh 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 1 ]] && grep -q "1 passed, 1 failed" <<<"$out" && grep -q "b.test.sh" <<<"$out"; then
    ok "runner exits 1, reports 1 passed 1 failed, and names b.test.sh in the failure summary"
  else
    bad "runner did not fail naming b.test.sh (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
  fi
}

test_runner_discovers_new_test_file_without_edit() {
  local dir="$FIXTURE_DIR/auto-discover"
  setup_fixture "$dir"
  write_green_test "$dir/src/hooks/tests/a.test.sh"

  local before_hash after_hash out status
  before_hash="$(shasum "$dir/scripts/run-hook-tests.sh")"

  write_green_test "$dir/src/hooks/tests/c.test.sh"

  set +e
  out="$(cd "$dir" && ./scripts/run-hook-tests.sh 2>&1)"
  status=$?
  set -e

  after_hash="$(shasum "$dir/scripts/run-hook-tests.sh")"

  if [[ "$status" -eq 0 ]] && grep -q "2 passed, 0 failed" <<<"$out" && [[ "$before_hash" == "$after_hash" ]]; then
    ok "runner auto-discovers a newly added .test.sh file without any edit to run-hook-tests.sh"
  else
    bad "runner did not auto-discover the new test file (status=$status)"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
  fi
}

echo "run-hook-tests.sh — unit tests"
echo

test_runner_passes_all_green_tests
test_runner_fails_and_names_failed_file
test_runner_discovers_new_test_file_without_edit

echo
if [[ "$fail" -eq 0 ]]; then
  echo -e "\033[32mrun-hook-tests tests: PASS\033[0m"
else
  echo -e "\033[31mrun-hook-tests tests: FAIL\033[0m"
fi
exit "$fail"
