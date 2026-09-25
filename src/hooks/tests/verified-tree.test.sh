#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VT="$SCRIPT_DIR/../verified-tree.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A repo with work in progress (a tracked edit and an untracked file) and a
# scratch dir whose last test row and static exits are given.
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
    printf 'a2\n' > a.txt
    printf 'new\n' > b.txt
  ) >/dev/null
  S="$D/.context/ship-run/T1"
  mkdir -p "$S"
  printf '| test | #<RUN> | 2026-01-01T00:00:00Z | - | %s | 0 | 0 | 0 | 0 | |\n' "${1:-pass}" > "$S/phase-status-test.md"
  printf 'typecheck=%s\nlint=%s\n' "${2:-0}" "${3:-0}" > "$S/static-exits.txt"
}

vt() { (cd "$D" && bash "$VT" "$@" "$S"); }

assert_check() {
  local name="$1" expected="$2" got
  got="$(vt check)"
  if [ "$got" = "verified_tree=$expected" ]; then log_pass "$name"; else log_fail "$name (got '$got')"; fi
}

test_preflight_reports_the_proof() {
  setup
  vt record >/dev/null
  local out
  out="$(cd "$D" && bash "$SCRIPT_DIR/../pr-preflight.sh" --task T1 --config /nonexistent 2>/dev/null)"
  if printf '%s' "$out" | grep -qx 'verified_tree=yes'; then log_pass "pr-preflight prints verified_tree=yes for a recorded green tree"; else log_fail "pr-preflight did not report the proof ($out)"; fi
}

test_green_tree_is_verified() {
  setup
  vt record >/dev/null
  assert_check "a recorded green tree checks as verified" yes
}

test_commits_keep_the_proof() {
  setup
  vt record >/dev/null
  (cd "$D" && git add a.txt && git commit -qm "feat: a" && git add b.txt && git commit -qm "feat: b")
  assert_check "atomic commits of the same content keep the tree verified" yes
}

test_an_edit_breaks_the_proof() {
  setup
  vt record >/dev/null
  printf 'changed\n' > "$D/b.txt"
  assert_check "an edit after recording makes the checks run" no
}

test_a_new_untracked_file_breaks_the_proof() {
  setup
  vt record >/dev/null
  printf 'x\n' > "$D/c.txt"
  assert_check "a new untracked file makes the checks run" no
}

test_scratch_writes_do_not_break_the_proof() {
  setup
  vt record >/dev/null
  printf 'later\n' > "$S/anything.md"
  assert_check "writes under .context do not count" yes
}

test_red_results_are_never_recorded() {
  setup fail 0 0
  vt record >/dev/null
  assert_check "a failed suite is never recorded as verified" no
  setup pass 0 1
  vt record >/dev/null
  assert_check "a failed lint is never recorded as verified" no
  setup skip 0 0
  vt record >/dev/null
  assert_check "a skipped suite is never recorded as verified" no
}

test_no_record_means_no() {
  setup
  assert_check "nothing recorded means the checks run" no
}

test_preflight_reports_the_proof
test_green_tree_is_verified
test_commits_keep_the_proof
test_an_edit_breaks_the_proof
test_a_new_untracked_file_breaks_the_proof
test_scratch_writes_do_not_break_the_proof
test_red_results_are_never_recorded
test_no_record_means_no

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
