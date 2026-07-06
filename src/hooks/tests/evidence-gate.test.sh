#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_SCRIPT="$SCRIPT_DIR/../evidence-gate.sh"

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

make_repo() {
  local dir
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p src
    echo "one" > src/a.ts
    echo "one test" > src/a.test.ts
    echo "two" > src/b.ts
    git add -A
    git commit -q -m "initial"
  )
  printf '%s' "$dir"
}

make_repo_no_tests() {
  local dir
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p src
    echo "one" > src/a.ts
    echo "two" > src/b.ts
    git add -A
    git commit -q -m "initial"
  )
  printf '%s' "$dir"
}

extract_json_array() {
  local json="$1" key="$2"
  printf '%s' "$json" | sed -n "s/.*\"$key\":\\[\\([^]]*\\)\\].*/\\1/p"
}

extract_json_number() {
  local json="$1" key="$2"
  printf '%s' "$json" | sed -n "s/.*\"$key\":\\([0-9]*\\).*/\\1/p"
}

test_untouched_test_file_marks_only_missing_as_untested() {
  local name="a touched file with no matching test appears in untested"
  local repo touched out
  repo="$(make_repo)"
  touched="$repo/touched.txt"
  printf 'src/a.ts\nsrc/b.ts\n' > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  local untested_arr
  untested_arr="$(extract_json_array "$out" untested)"
  if [ "$untested_arr" != '"src/b.ts"' ]; then
    log_fail "$name (untested was: $untested_arr)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_touched_test_file_excluded_from_requirement() {
  local name="a touched file that is itself a test is excluded from the requirement"
  local repo touched out
  repo="$(make_repo)"
  touched="$repo/touched.txt"
  printf 'src/a.test.ts\n' > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  local untested_arr
  untested_arr="$(extract_json_array "$out" untested)"
  if [ -n "$untested_arr" ]; then
    log_fail "$name (untested was: $untested_arr)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_empty_touched_list() {
  local name="empty list of touched files yields untested empty and total 0"
  local repo touched out
  repo="$(make_repo)"
  touched="$repo/touched.txt"
  : > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  local untested_arr total
  untested_arr="$(extract_json_array "$out" untested)"
  total="$(extract_json_number "$out" total)"

  if [ -n "$untested_arr" ] || [ "$total" != "0" ]; then
    log_fail "$name (untested: $untested_arr, total: $total)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_repo_with_no_test_files() {
  local name="repository with no test files sends all touched source files to untested"
  local repo touched out
  repo="$(make_repo_no_tests)"
  touched="$repo/touched.txt"
  printf 'src/a.ts\nsrc/b.ts\n' > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  local untested_arr
  untested_arr="$(extract_json_array "$out" untested)"
  if ! printf '%s' "$untested_arr" | grep -qF '"src/a.ts"'; then
    log_fail "$name (missing src/a.ts in untested: $untested_arr)"
    rm -rf "$repo"
    return
  fi
  if ! printf '%s' "$untested_arr" | grep -qF '"src/b.ts"'; then
    log_fail "$name (missing src/b.ts in untested: $untested_arr)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_output_is_valid_json_with_three_keys() {
  local name="output is valid JSON with the three keys"
  local repo touched out
  repo="$(make_repo)"
  touched="$repo/touched.txt"
  printf 'src/a.ts\nsrc/b.ts\n' > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  if ! printf '%s' "$out" | grep -qE '^\{.*"tested":\[.*\].*"untested":\[.*\].*"total":[0-9]+\}$'; then
    log_fail "$name (output was: $out)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_source_file_with_matching_test_appears_only_in_tested() {
  local name="a source file with a matching test appears only in tested"
  local repo touched out
  repo="$(make_repo)"
  touched="$repo/touched.txt"
  printf 'src/a.ts\n' > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  local tested_arr untested_arr
  tested_arr="$(extract_json_array "$out" tested)"
  untested_arr="$(extract_json_array "$out" untested)"

  if [ "$tested_arr" != '"src/a.ts"' ]; then
    log_fail "$name (tested was: $tested_arr)"
    rm -rf "$repo"
    return
  fi
  if [ -n "$untested_arr" ]; then
    log_fail "$name (untested was: $untested_arr)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

make_repo_dir_convention() {
  local dir
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p src/__tests__
    echo "one" > src/a.ts
    echo "one test" > src/__tests__/a.ts
    git add -A
    git commit -q -m "initial"
  )
  printf '%s' "$dir"
}

test_source_with_test_in_dunder_tests_dir_is_tested() {
  local name="a source file with its only test under __tests__/ (no .test./.spec. marker) is not reported as untested"
  local repo touched out
  repo="$(make_repo_dir_convention)"
  touched="$repo/touched.txt"
  printf 'src/a.ts\n' > "$touched"

  out="$(cd "$repo" && bash "$EVIDENCE_SCRIPT" "$touched")"

  local tested_arr untested_arr
  tested_arr="$(extract_json_array "$out" tested)"
  untested_arr="$(extract_json_array "$out" untested)"

  if [ "$tested_arr" != '"src/a.ts"' ] || [ -n "$untested_arr" ]; then
    log_fail "$name (tested was: $tested_arr, untested was: $untested_arr)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_reads_from_stdin_when_no_positional_arg() {
  local name="reads touched files from stdin when no positional argument is given"
  local repo out
  repo="$(make_repo)"

  out="$(cd "$repo" && printf 'src/a.ts\nsrc/b.ts\n' | bash "$EVIDENCE_SCRIPT")"

  local untested_arr
  untested_arr="$(extract_json_array "$out" untested)"
  if [ "$untested_arr" != '"src/b.ts"' ]; then
    log_fail "$name (untested was: $untested_arr)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_untouched_test_file_marks_only_missing_as_untested
test_touched_test_file_excluded_from_requirement
test_empty_touched_list
test_repo_with_no_test_files
test_output_is_valid_json_with_three_keys
test_source_file_with_matching_test_appears_only_in_tested
test_source_with_test_in_dunder_tests_dir_is_tested
test_reads_from_stdin_when_no_positional_arg

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
