#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_TESTS_DIR="${REPO_ROOT}/src/hooks/tests"

PASSED=0
FAILED=0
FAILED_FILES=()

echo "Running hook tests in ${HOOK_TESTS_DIR}..."
echo ""

while IFS= read -r -d '' test_file; do
  test_name="$(basename "$test_file")"
  echo "==> ${test_name}"
  if bash "$test_file"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("$test_name")
  fi
  echo ""
done < <(find "$HOOK_TESTS_DIR" -maxdepth 1 -name "*.test.sh" -print0 | sort -z)

echo "${PASSED} passed, ${FAILED} failed"

if [[ "$FAILED" -eq 0 ]]; then
  exit 0
else
  echo ""
  echo "Failed test files:"
  for failed_file in "${FAILED_FILES[@]}"; do
    echo "  - ${failed_file}"
  done
  exit 1
fi
