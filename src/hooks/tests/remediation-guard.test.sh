#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RG="$SCRIPT_DIR/../remediation-guard.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A repo at its base commit, then the develop change on top of it: a tracked
# edit and a new untracked file, the shape of the live case.
setup() {
  D="$(mktemp -d)"
  (
    cd "$D"
    git init -q
    git config user.email t@t
    git config user.name t
    printf 'a\n' > a.txt
    printf '.context/\n' > .gitignore
    git add -A && git commit -qm init
  ) >/dev/null
  S="$D/.context/ship-run/T1"
  mkdir -p "$S"
  (cd "$D" && git rev-parse HEAD) > "$S/pre-quality-snapshot.sha"
  printf 'a2\n' > "$D/a.txt"
  printf 'new\n' > "$D/b.txt"
}

rg() { (cd "$D" && bash "$RG" "$@" "$S"); }

erase_change() {
  (cd "$D" && git checkout -q -- a.txt && rm -f b.txt)
}

test_a_fix_that_erases_the_change_is_restored() {
  local name="a fix that reverts the whole change to the base is detected and the change put back"
  setup
  rg snapshot
  erase_change
  local out
  out="$(rg check)"
  if [ "$out" = "erased=yes" ] && [ "$(cat "$D/a.txt")" = "a2" ] && [ "$(cat "$D/b.txt")" = "new" ] \
    && [ -f "$S/remediation-erased.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (out=$out a=$(cat "$D/a.txt" 2>/dev/null) b=$(cat "$D/b.txt" 2>/dev/null))"
  fi
}

test_a_fix_that_keeps_part_of_the_change_is_left_alone() {
  local name="a fix that keeps any part of the change is not judged"
  setup
  rg snapshot
  (cd "$D" && git checkout -q -- a.txt)
  local out
  out="$(rg check)"
  if [ "$out" = "erased=no" ] && [ "$(cat "$D/a.txt")" = "a" ] && [ ! -f "$S/remediation-erased.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (out=$out a=$(cat "$D/a.txt"))"
  fi
}

test_an_empty_change_before_the_fix_is_not_an_erasure() {
  local name="a tree already at the base before the fix is not an erasure"
  setup
  erase_change
  rg snapshot
  local out
  out="$(rg check)"
  if [ "$out" = "erased=no" ] && [ ! -f "$S/remediation-erased.txt" ]; then log_pass "$name"; else log_fail "$name (out=$out)"; fi
}

test_no_snapshot_means_no() {
  local name="a check with no snapshot reports nothing erased"
  setup
  erase_change
  local out
  out="$(rg check)"
  if [ "$out" = "erased=no" ]; then log_pass "$name"; else log_fail "$name (out=$out)"; fi
}

test_scratch_writes_do_not_count() {
  local name="writes under .context neither hide nor fake an erasure"
  setup
  rg snapshot
  erase_change
  printf 'report\n' > "$S/remediation-fix-report.md"
  local out
  out="$(rg check)"
  if [ "$out" = "erased=yes" ]; then log_pass "$name"; else log_fail "$name (out=$out)"; fi
}

test_a_fix_that_erases_the_change_is_restored
test_a_fix_that_keeps_part_of_the_change_is_left_alone
test_an_empty_change_before_the_fix_is_not_an_erasure
test_no_snapshot_means_no
test_scratch_writes_do_not_count

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
