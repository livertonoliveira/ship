#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_DIFF_SCRIPT="$SCRIPT_DIR/../capture-diff.sh"

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
    git add -A
    git commit -q -m "initial"
    git remote add origin .
    git branch -q origin/main
    git checkout -q -b feature
  )
  printf '%s' "$dir"
}

test_capture_produces_valid_unified_diff_with_new_and_modified_files() {
  local name="capturing a working tree with a new file and a modified file produces a valid unified diff with exit code 0"
  local repo out
  repo="$(make_repo)"
  (
    cd "$repo"
    echo "one changed" > src/a.ts
    echo "brand new" > src/new.ts
  )
  out="$repo/out.md"

  local rc=0
  (cd "$repo" && bash "$CAPTURE_DIFF_SCRIPT" "$out") || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$repo"
    return
  fi

  if ! grep -q '^diff --git ' "$out"; then
    log_fail "$name (output file has no 'diff --git' header: $(cat "$out"))"
    rm -rf "$repo"
    return
  fi

  if ! grep -q 'src/new.ts' "$out"; then
    log_fail "$name (new untracked file did not appear in diff)"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_clean_working_tree_produces_empty_file_with_success() {
  local name="capturing a clean working tree relative to merge-base produces an empty output file with exit code 0"
  local repo out
  repo="$(make_repo)"
  out="$repo/out.md"

  local rc=0
  (cd "$repo" && bash "$CAPTURE_DIFF_SCRIPT" "$out") || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$repo"
    return
  fi

  if [ ! -f "$out" ]; then
    log_fail "$name (output file was not created)"
    rm -rf "$repo"
    return
  fi

  if [ -s "$out" ]; then
    log_fail "$name (output file is not empty: $(cat "$out"))"
    rm -rf "$repo"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_malformed_content_fails_loudly() {
  local name="asserting a non-empty result without a 'diff --git' header fails loudly and cleans up the corrupted file"
  local dir out

  dir="$(mktemp -d)"
  out="$dir/out.md"
  printf 'not a real diff\njust some noise\n' > "$out"

  local rc=0
  local stderr_output
  stderr_output="$(bash "$CAPTURE_DIFF_SCRIPT" --assert-only "$out" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$stderr_output" | grep -qF "not a valid unified diff. Re-capture before proceeding."; then
    log_fail "$name (stderr did not contain the malformed diff message: $stderr_output)"
    rm -rf "$dir"
    return
  fi

  if [ -s "$out" ]; then
    log_fail "$name (output file still has corrupted content: $(cat "$out"))"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_capture_produces_valid_unified_diff_with_new_and_modified_files
test_clean_working_tree_produces_empty_file_with_success
test_malformed_content_fails_loudly

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
