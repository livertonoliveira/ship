#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SCRIPT="$SCRIPT_DIR/../guard-destructive-git.sh"

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

event_for() {
  local command="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$command"
}

assert_blocked() {
  local name="$1" command="$2" status
  set +e
  event_for "$command" | bash "$GUARD_SCRIPT" >/dev/null 2>/tmp/guard-stderr.$$
  status=$?
  set -e
  if [ "$status" -eq 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (expected exit 2, got $status)"
  fi
  rm -f /tmp/guard-stderr.$$
}

assert_allowed() {
  local name="$1" command="$2" status
  set +e
  event_for "$command" | bash "$GUARD_SCRIPT" >/dev/null 2>/tmp/guard-stderr.$$
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (expected exit 0, got $status)"
  fi
  rm -f /tmp/guard-stderr.$$
}

assert_blocked "blocks git clean -fd" "git clean -fd"
assert_blocked "blocks git clean -df" "git clean -df"
assert_blocked "blocks git clean --force" "git clean --force -d"
assert_blocked "blocks git checkout -- ." "git checkout -- ."
assert_blocked "blocks git checkout -- <file>" "git checkout -- src/app.ts"
assert_blocked "blocks git checkout ." "git checkout ."
assert_blocked "blocks git reset --hard" "git reset --hard origin/main"
assert_blocked "blocks git branch -D" "git branch -D feature/old"
assert_blocked "blocks git push --force" "git push --force origin main"

assert_allowed "allows git clean -n (dry run)" "git clean -nfd"
assert_allowed "allows git status" "git status"
assert_allowed "allows git checkout <branch>" "git checkout feature/foo"
assert_allowed "allows git checkout -b <branch>" "git checkout -b feature/new"
assert_allowed "allows git reset (soft, default)" "git reset HEAD~1"
assert_allowed "allows git stash -u" "git stash -u"
assert_allowed "allows git push (no force)" "git push origin main"
assert_allowed "allows non-git command" "npm test"

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
