#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPAND="$SCRIPT_DIR/../files-expand.sh"

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

expand_text() {
  local f
  f="$(mktemp)"
  printf '%s\n' "$1" > "$f"
  bash "$EXPAND" "$f"
  rm -f "$f"
}

test_group_expands_one_line_per_path() {
  local name="a brace group in ## Files becomes one line per alternative, keeping verb and intent"
  local out
  out="$(expand_text "## Files
- modify \`src/use-{a,b}.ts\` — x")"
  if [ "$out" = "## Files
- modify \`src/use-a.ts\` — x
- modify \`src/use-b.ts\` — x" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_nested_and_multiple_groups_expand_like_bash() {
  local name="nested and consecutive groups expand to the same set bash would produce"
  local out
  out="$(expand_text "### Files
- create a/{x,{y,z}}/{p,q}.ts" | sed 1d | sed 's/^- create //')"
  if [ "$out" = "a/x/p.ts
a/x/q.ts
a/y/p.ts
a/y/q.ts
a/z/p.ts
a/z/q.ts" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_comma_free_group_stays_literal() {
  local name="a group with no top-level comma is left literal, as bash leaves it"
  local out
  out="$(expand_text "## Files
- modify src/{id}.ts")"
  if printf '%s' "$out" | grep -qF -- '- modify src/{id}.ts'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_lines_outside_files_are_untouched() {
  local name="brace groups outside a Files section pass through unchanged"
  local out
  out="$(expand_text "## Files
- modify src/a.ts
## Acceptance Criteria
- {a,b} stays")"
  if printf '%s' "$out" | grep -qF -- '- {a,b} stays'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_spec_content_is_never_evaluated() {
  local name="a path is expanded as text, never run through the shell"
  local marker out
  marker="$(mktemp -d)/pwned"
  out="$(expand_text "## Files
- modify src/{a,\$(touch $marker)}.ts")"
  if [ ! -e "$marker" ] && printf '%s' "$out" | grep -qF "src/\$(touch $marker).ts"; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_group_expands_one_line_per_path
test_nested_and_multiple_groups_expand_like_bash
test_comma_free_group_stays_literal
test_lines_outside_files_are_untouched
test_spec_content_is_never_evaluated

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
