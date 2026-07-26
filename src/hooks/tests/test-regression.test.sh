#!/usr/bin/env bash

# The test phase is allowed to add coverage and allowed to leave it alone. What
# it must never do is replace a file and lose cases that were already there —
# observed twice in live runs, with the phase still reporting green because the
# suite it ran was the smaller one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TR="$SCRIPT_DIR/../test-regression.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

new_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    mkdir -p src
    cat > src/add.test.js <<'EOF'
import test from 'node:test'
import assert from 'node:assert'
test('adds two positives', () => { assert.equal(1 + 1, 2) })
test('adds negatives', () => { assert.equal(-1 + -1, -2) })
test('adds zero', () => { assert.equal(0 + 0, 0) })
EOF
    git add -A
    git commit -qm init
  )
}

test_counts_cases_not_groups() {
  local name="a snapshot counts test cases, not describe/context groups"
  local dir n
  dir="$(mktemp -d)"
  new_repo "$dir"
  (cd "$dir" && printf "describe('grouping', () => {\n  it('one', () => {})\n})\n" >> src/add.test.js)
  (cd "$dir" && bash "$TR" snapshot snap.txt)
  n="$(awk -F'\t' '$1 == "src/add.test.js" { print $2 }' "$dir/snap.txt")"
  rm -rf "$dir"

  # 3 test() + 1 it() = 4; the describe() wrapper must not inflate it.
  if [ "$n" = "4" ]; then
    log_pass "$name"
  else
    log_fail "$name (counted $n, expected 4)"
  fi
}

test_shrinking_file_is_a_regression() {
  local name="a file that loses cases is reported, with before and after counts"
  local dir out rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    bash "$TR" snapshot pre.txt
    # Exactly the observed failure: the worker rewrites the file to just the
    # contract's slots, dropping what develop had already asserted.
    cat > src/add.test.js <<'EOF'
import test from 'node:test'
import assert from 'node:assert'
test('adds two positives', () => { assert.equal(1 + 1, 2) })
EOF
    bash "$TR" snapshot post.txt
  )
  out="$(cd "$dir" && bash "$TR" check pre.txt post.txt)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^src/add.test.js 3 1$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_growing_file_is_not_a_regression() {
  local name="a file that gains cases is not reported"
  local dir rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    bash "$TR" snapshot pre.txt
    printf "test('adds fractions', () => { assert.equal(0.5 + 0.5, 1) })\n" >> src/add.test.js
    bash "$TR" snapshot post.txt
    bash "$TR" check pre.txt post.txt
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — growth was flagged as a regression)"
  fi
}

test_new_file_is_not_a_regression() {
  local name="a test file that did not exist before is not a regression"
  local dir rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    bash "$TR" snapshot pre.txt
    printf "test('subtracts', () => {})\n" > src/sub.test.js
    git add -A
    bash "$TR" snapshot post.txt
    bash "$TR" check pre.txt post.txt
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
}

test_untouched_tree_is_clean() {
  local name="two snapshots with no edits between them report nothing"
  local dir rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    bash "$TR" snapshot pre.txt
    bash "$TR" snapshot post.txt
    bash "$TR" check pre.txt post.txt
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — a no-op run reported a regression)"
  fi
}

test_python_and_go_cases_are_counted() {
  local name="pytest and Go test declarations are counted too"
  local dir py go
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    mkdir -p tests
    printf 'def test_alpha():\n    pass\n\ndef test_beta():\n    pass\n' > tests/test_thing.py
    printf 'package main\n\nfunc TestAlpha(t *testing.T) {}\nfunc TestBeta(t *testing.T) {}\n' > tests/thing_test.go
    git add -A
    bash "$TR" snapshot snap.txt
  )
  py="$(awk -F'\t' '$1 == "tests/test_thing.py" { print $2 }' "$dir/snap.txt")"
  go="$(awk -F'\t' '$1 == "tests/thing_test.go" { print $2 }' "$dir/snap.txt")"
  rm -rf "$dir"

  if [ "$py" = "2" ] && [ "$go" = "2" ]; then
    log_pass "$name"
  else
    log_fail "$name (python=$py go=$go, expected 2 and 2)"
  fi
}

test_wired_into_the_pipeline() {
  local name="pipeline.sh baselines before the fan-out and checks after it"
  local pipeline="$SCRIPT_DIR/../pipeline.sh"
  if grep -q 'test-regression.sh" snapshot "\$SCRATCH/tests-pre.txt"' "$pipeline" \
    && grep -q 'test-regression.sh" check "\$SCRATCH/tests-pre.txt"' "$pipeline" \
    && grep -q 'test-regression.sh' <(printf '%s' "$(grep REQUIRED_HOOKS "$pipeline")"); then
    log_pass "$name"
  else
    log_fail "$name (missing snapshot, check, or REQUIRED_HOOKS entry)"
  fi
}

test_brief_carries_acceptance_criteria() {
  local name="the test brief carries acceptance criteria, not only tagged scenarios"
  local pipeline="$SCRIPT_DIR/../pipeline.sh"
  # The defect this closes: an AC with no @SC tag reached the worker nowhere,
  # and the worker is told to invent nothing beyond what it was given.
  if grep -q '## Acceptance Criteria' "$pipeline" \
    && grep -q 'Every criterion above needs an assertion' "$pipeline"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_brief_lists_existing_tests() {
  local name="the test brief names existing suites so they are extended, not replaced"
  local pipeline="$SCRIPT_DIR/../pipeline.sh"
  if grep -q '## Existing tests' "$pipeline" \
    && grep -q 'never remove a case you did not write' "$pipeline"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_counts_cases_not_groups
test_shrinking_file_is_a_regression
test_growing_file_is_not_a_regression
test_new_file_is_not_a_regression
test_untouched_tree_is_clean
test_python_and_go_cases_are_counted
test_wired_into_the_pipeline
test_brief_carries_acceptance_criteria
test_brief_lists_existing_tests

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
