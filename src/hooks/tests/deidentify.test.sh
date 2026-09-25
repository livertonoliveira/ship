#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEID="$SCRIPT_DIR/../deidentify.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

assert_out() {
  local name="$1" input="$2" expected="$3" got
  shift 3
  got="$(printf '%s\n' "$input" | bash "$DEID" "$@")"
  if [ "$got" = "$expected" ]; then log_pass "$name"; else log_fail "$name (got '$got', expected '$expected')"; fi
}

test_tag_only_lines_are_dropped() {
  assert_out "a tag-only line disappears, the scenario stays" \
    "$(printf '%s\n' '@SC-3 @unit' 'Scenario: ignores a duplicate event')" \
    'Scenario: ignores a duplicate event'
}

test_inline_tags_are_removed() {
  assert_out "inline scenario and layer tags are removed" \
    'Scenario: checkout @SC-9 @e2e' \
    'Scenario: checkout  '
}

test_bare_ids_and_their_separators() {
  assert_out "an id with a colon" '- AC-1: user can reset password' '- user can reset password'
  assert_out "a bold id with an em dash" '- **AC-2** — rejects expired tokens' '- rejects expired tokens'
  assert_out "a parenthesised id" '  Given a stored event (SC-3)' '  Given a stored event'
  assert_out "a marker id" 'TEST-REQ-1 marker' 'marker'
}

test_linear_keys() {
  assert_out "--key strips that key only" 'fixes ABC-45 not ABC-46' 'fixes not ABC-46' --key ABC-45
  assert_out "--team strips every key of the team" 'fixes ABC-45 and (ABC-46)' 'fixes and' --team ABC
}

test_lookalikes_survive() {
  assert_out "UTF-8 and ISO-8601 are kept" 'encode as UTF-8, dates as ISO-8601' 'encode as UTF-8, dates as ISO-8601' --team ABC
  assert_out "Given/When/Then steps are untouched" \
    "$(printf '%s\n' '  When the same event is delivered twice' '  Then the second delivery is a no-op')" \
    "$(printf '%s\n' '  When the same event is delivered twice' '  Then the second delivery is a no-op')"
}

test_bad_arguments_fail() {
  if printf 'x\n' | bash "$DEID" --key 'not a key' >/dev/null 2>&1; then log_fail "malformed --key accepted"; else log_pass "malformed --key fails fast"; fi
  if printf 'x\n' | bash "$DEID" --bogus >/dev/null 2>&1; then log_fail "unknown flag accepted"; else log_pass "unknown flag fails fast"; fi
}

test_tag_only_lines_are_dropped
test_inline_tags_are_removed
test_bare_ids_and_their_separators
test_linear_keys
test_lookalikes_survive
test_bad_arguments_fail

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
