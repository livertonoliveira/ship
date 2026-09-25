#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COV="$SCRIPT_DIR/../coverage-correlate.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git config user.email t@t
    git config user.name t
    mkdir -p src tests/integration e2e
    printf '%s\n' \
      "describe('cart total', () => {" \
      "  it('applies the discount coupon to the cart total', () => {});" \
      "  it('rejects an expired coupon', () => {});" \
      "});" > src/cart.test.ts
    printf '%s\n' "test('POST /orders creates an order and returns 201', async () => {});" > tests/integration/orders.test.ts
    printf '%s\n' "test('user completes checkout with saved card', async () => {});" > e2e/checkout.spec.ts
    printf '%s\n' 'def test_sendsPasswordResetEmail(): pass' > tests/test_mail.py
    git add -A
    git commit -qm init
  ) >/dev/null
}

# The table row for an item id.
row_of() { grep -E "^\| $2 \|" <<<"$1" || true; }

# Field N (1-based, after the leading pipe) of a table row, trimmed.
field() { awk -F'|' -v n="$2" '{ gsub(/^ +| +$/, "", $(n + 1)); print $(n + 1) }' <<<"$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then log_pass "$1"; else log_fail "$1 (got '$2', expected '$3')"; fi
}

setup() {
  D="$(mktemp -d)"
  make_repo "$D"
  printf '%s\t%s\t%s\n' \
    AC-1 - 'apply discount coupon cart total' \
    AC-2 - 'create order returns 201' \
    SC-3 e2e 'checkout saved card complete' \
    SC-4 integration 'password reset email' \
    SC-5 unit 'expired coupon rejected' \
    SC-6 unit 'send password reset email' > "$D/items.tsv"
}

run_cov() { (cd "$D" && bash "$COV" --items items.tsv "$@"); }

test_bands_and_findings() {
  setup
  local out; out="$(run_cov)"
  assert_eq "a close unit match is covered" "$(field "$(row_of "$out" AC-1)" 4)" covered
  assert_eq "AC/REQ is reported at its best layer" "$(field "$(row_of "$out" AC-1)" 2)" unit
  assert_eq "a partial match is uncertain with a medium finding" "$(field "$(row_of "$out" AC-2)" 6)" medium
  assert_eq "a scenario only scores against its own layer" "$(field "$(row_of "$out" SC-4)" 6)" high
  assert_eq "light stemming joins rejects/rejected" "$(field "$(row_of "$out" SC-5)" 4)" covered
}

test_python_and_camel_case_names_are_tokenized() {
  setup
  local out; out="$(run_cov)"
  assert_eq "def test_sendsPasswordResetEmail covers 'send password reset email'" "$(field "$(row_of "$out" SC-6)" 4)" covered
}

test_disabled_layer_has_no_gate_impact() {
  setup
  local out; out="$(run_cov --layers unit,integration)"
  assert_eq "a scenario in a disabled layer is marked disabled" "$(field "$(row_of "$out" SC-3)" 4)" disabled
  assert_eq "disabled rows raise no finding" "$(field "$(row_of "$out" SC-3)" 6)" -
}

test_summary_lines() {
  setup
  local out; out="$(run_cov)"
  if grep -qE '^findings: high=[0-9]+ medium=[0-9]+$' <<<"$out" && grep -qE '^tests_scanned=[1-9]' <<<"$out"; then
    log_pass "summary lines are machine-readable"
  else
    log_fail "summary lines missing"
  fi
}

test_bad_input_fails() {
  setup
  if (cd "$D" && bash "$COV" --items missing.tsv >/dev/null 2>&1); then log_fail "missing items file accepted"; else log_pass "missing items file fails fast"; fi
  if run_cov --layers smoke >/dev/null 2>&1; then log_fail "unknown layer list accepted"; else log_pass "unknown layer list fails fast"; fi
}

test_bands_and_findings
test_python_and_camel_case_names_are_tokenized
test_disabled_layer_has_no_gate_impact
test_summary_lines
test_bad_input_fails

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
