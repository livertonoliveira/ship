#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.."

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

# Build a self-contained HOOK_DIR (copy of the real hooks) inside a git repo so
# init has everything it needs; the test then removes one hook to prove the guard.
setup_sandbox() {
  local dir="$1"
  cp "$HOOKS_DIR"/*.sh "$dir/"
  (
    cd "$dir"
    git init -q
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
    mkdir -p ship
    printf -- '- Language: bash\n' > ship/config.md
  )
}

test_missing_hook_fails_with_canonical_message() {
  local name="init aborts naming the missing hook and the resolved HOOK_DIR"
  local dir err rc=0
  dir="$(mktemp -d)"
  setup_sandbox "$dir"
  rm -f "$dir/diff-classify.sh"

  err="$(cd "$dir" && bash "$dir/pipeline.sh" init requirehookstask --mode fresh 2>&1 1>/dev/null)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (init exited 0 with a hook removed)"
    return
  fi
  if ! printf '%s' "$err" | grep -q 'MISSING HOOK(S).*diff-classify.sh'; then
    log_fail "$name (message did not name the missing hook: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q 'HOOK_DIR='; then
    log_fail "$name (message did not stamp the resolved HOOK_DIR: $err)"
    return
  fi
  log_pass "$name"
}

test_all_hooks_present_init_succeeds() {
  local name="init runs clean when every required hook is present"
  local dir rc=0
  dir="$(mktemp -d)"
  setup_sandbox "$dir"

  (cd "$dir" && bash "$dir/pipeline.sh" init requirehookstask --mode fresh >/dev/null 2>&1) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (init exited $rc with all hooks present)"
    return
  fi
  log_pass "$name"
}

test_required_list_matches_actual_calls() {
  local name="every hook pipeline.sh shells out to is in REQUIRED_HOOKS"
  local called missing=""
  # Extract sibling hooks invoked as bash "$HOOK_DIR/<name>.sh"
  called="$(grep -oE '\$HOOK_DIR/[a-z-]+\.sh' "$HOOKS_DIR/pipeline.sh" | sed 's#\$HOOK_DIR/##' | sort -u)"
  local required
  required="$(grep -E '^REQUIRED_HOOKS=' "$HOOKS_DIR/pipeline.sh")"
  local h
  for h in $called; do
    printf '%s' "$required" | grep -q "$h" || missing="$missing $h"
  done
  if [ -n "$missing" ]; then
    log_fail "$name (called but not guarded:$missing)"
    return
  fi
  log_pass "$name"
}

test_missing_hook_fails_with_canonical_message
test_all_hooks_present_init_succeeds
test_required_list_matches_actual_calls

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
