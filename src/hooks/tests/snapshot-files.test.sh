#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_SCRIPT="$SCRIPT_DIR/../snapshot-files.sh"

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
    echo "two" > src/b.ts
    echo "foo base" > src/foo.ts
    git add -A
    git commit -q -m "initial"
    git remote add origin .
    git branch -q origin/main
    git checkout -q -b feature
  )
  printf '%s' "$dir"
}

test_snapshot_mode_outputs_sorted_hash_path_lines() {
  local name="snapshot mode outputs a sorted hash-and-path line per modified file with exit code 0"
  local repo out
  repo="$(make_repo)"
  (
    cd "$repo"
    echo "one-changed" > src/a.ts
    echo "two-changed" > src/b.ts
  )
  out="$repo/out.txt"
  local rc=0
  (cd "$repo" && bash "$SNAPSHOT_SCRIPT" snapshot "$out") || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    return
  fi

  local line_count
  line_count="$(wc -l < "$out" | tr -d ' ')"
  if [ "$line_count" -ne 2 ]; then
    log_fail "$name (expected 2 lines, got $line_count)"
    return
  fi

  if ! awk '{print $2}' "$out" | grep -qx "src/a.ts"; then
    log_fail "$name (missing src/a.ts entry)"
    return
  fi
  if ! awk '{print $2}' "$out" | grep -qx "src/b.ts"; then
    log_fail "$name (missing src/b.ts entry)"
    return
  fi

  if ! awk '{print $1}' "$out" | grep -qE '^[0-9a-f]{40}$'; then
    log_fail "$name (hash column is not a sha1)"
    return
  fi

  local sorted
  sorted="$(sort "$out")"
  if [ "$sorted" != "$(cat "$out")" ]; then
    log_fail "$name (lines are not lexicographically sorted)"
    return
  fi

  log_pass "$name"
  rm -rf "$repo"
}

test_deleted_file_appears_in_diff() {
  local name="a file deleted between snapshots is reported by diff mode"
  local repo work pre post
  repo="$(make_repo)"
  work="$(mktemp -d)"
  (
    cd "$repo"
    echo "foo modified" > src/foo.ts
    git add -A
    git commit -q -m "modify foo"
  )
  pre="$work/pre.txt"
  (cd "$repo" && bash "$SNAPSHOT_SCRIPT" snapshot "$pre")

  if ! grep -q "src/foo.ts" "$pre"; then
    log_fail "$name (setup failed: src/foo.ts missing from pre-snapshot)"
    return
  fi

  (cd "$repo" && rm src/foo.ts)

  post="$work/post.txt"
  local rc=0
  (cd "$repo" && bash "$SNAPSHOT_SCRIPT" snapshot "$post") || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (post-snapshot exit code was $rc)"
    return
  fi

  local diff_output
  diff_output="$(cd "$repo" && bash "$SNAPSHOT_SCRIPT" diff "$pre" "$post")"

  if ! printf '%s\n' "$diff_output" | grep -qx "src/foo.ts"; then
    log_fail "$name (deleted file not listed in diff output: $diff_output)"
    return
  fi

  log_pass "$name"
  rm -rf "$repo" "$work"
}

test_diff_mode_fails_on_missing_snapshot() {
  local pre="$1"
  local post="$2"
  local missing_label="$3"
  local name="diff mode fails with a non-zero exit code and reports the missing snapshot when the $missing_label snapshot file is absent"

  local repo tmp
  repo="$(make_repo)"
  tmp="$(mktemp -d)"

  if [ "$pre" != "missing" ]; then
    (cd "$repo" && bash "$SNAPSHOT_SCRIPT" snapshot "$tmp/pre.txt")
    pre="$tmp/pre.txt"
  else
    pre="$tmp/nonexistent-pre.txt"
  fi

  if [ "$post" != "missing" ]; then
    (cd "$repo" && bash "$SNAPSHOT_SCRIPT" snapshot "$tmp/post.txt")
    post="$tmp/post.txt"
  else
    post="$tmp/nonexistent-post.txt"
  fi

  local rc=0
  local stderr_output
  stderr_output="$(cd "$repo" && bash "$SNAPSHOT_SCRIPT" diff "$pre" "$post" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$repo" "$tmp"
    return
  fi

  local expected_missing
  if [ "$missing_label" = "pre" ]; then
    expected_missing="$pre"
  else
    expected_missing="$post"
  fi

  if ! printf '%s' "$stderr_output" | grep -qF "$expected_missing"; then
    log_fail "$name (stderr did not mention missing file: $stderr_output)"
    rm -rf "$repo" "$tmp"
    return
  fi

  log_pass "$name"
  rm -rf "$repo" "$tmp"
}

test_snapshot_mode_outputs_sorted_hash_path_lines
test_deleted_file_appears_in_diff
test_diff_mode_fails_on_missing_snapshot "missing" "present" "pre"
test_diff_mode_fails_on_missing_snapshot "present" "missing" "post"

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
