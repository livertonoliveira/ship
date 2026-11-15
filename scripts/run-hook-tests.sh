#!/usr/bin/env bash
# Runs src/hooks/tests/*.test.sh, several files at a time.
#
#   run-hook-tests.sh [name ...]     names filter by substring; none = every file
#   HOOK_TEST_JOBS=<n>               files in flight at once (default: the core count, capped at 8)
#
# Each file's output is held back and printed whole, in name order, so a
# parallel run reads exactly like a serial one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_TESTS_DIR="${REPO_ROOT}/src/hooks/tests"

cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
[ "$cores" -gt 8 ] && cores=8
JOBS="${HOOK_TEST_JOBS:-$cores}"
case "$JOBS" in ''|*[!0-9]*|0) echo "run-hook-tests.sh: HOOK_TEST_JOBS must be a positive number, got '$JOBS'" >&2; exit 2 ;; esac

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

LIST="$OUT_DIR/files.list"
find "$HOOK_TESTS_DIR" -maxdepth 1 -name "*.test.sh" | LC_ALL=C sort > "$LIST.all"
if [ "$#" -gt 0 ]; then
  : > "$LIST"
  for want in "$@"; do
    { grep -F -- "$want" "$LIST.all" || true; } >> "$LIST"
  done
  LC_ALL=C sort -u -o "$LIST" "$LIST"
else
  cp "$LIST.all" "$LIST"
fi

TOTAL="$(wc -l < "$LIST" | tr -d ' ')"
echo "Running ${TOTAL} hook test file(s) in ${HOOK_TESTS_DIR}, ${JOBS} at a time..."
echo ""

export OUT_DIR
# shellcheck disable=SC2016
tr '\n' '\0' < "$LIST" | xargs -0 -n 1 -P "$JOBS" bash -c '
  name="$(basename "$1")"
  if bash "$1" > "$OUT_DIR/$name.log" 2>&1; then echo 0; else echo 1; fi > "$OUT_DIR/$name.rc"
' _ || true

PASSED=0
FAILED=0
FAILED_FILES=()

while IFS= read -r test_file; do
  [ -n "$test_file" ] || continue
  test_name="$(basename "$test_file")"
  echo "==> ${test_name}"
  cat "$OUT_DIR/$test_name.log" 2>/dev/null || true
  if [ "$(cat "$OUT_DIR/$test_name.rc" 2>/dev/null || echo 1)" = "0" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("$test_name")
  fi
  echo ""
done < "$LIST"

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
