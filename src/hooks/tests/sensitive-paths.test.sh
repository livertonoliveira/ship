#!/usr/bin/env bash

# `## Sensitive Paths` has three shapes and the middle one used to silently
# disable the protection: a section present but carrying only comments — exactly
# what /ship:init leaves behind — read as "this project has none", so a doc-only
# change under auth/ classified trivial and skipped the quality fan-out.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="$SCRIPT_DIR/../diff-classify.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass_count=0
fail_count=0
log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

doc_diff_under_auth() {
  printf 'diff --git a/auth/README.md b/auth/README.md\n--- a/auth/README.md\n+++ b/auth/README.md\n@@ -1 +1 @@\n-a\n+b\n' > "$1"
}

classify_with() {
  local dir="$1" cfg="$2"
  bash "$CLASSIFY" "$dir/diff.md" "$dir/out.txt" --config "$cfg" 2>/dev/null | head -1 | awk '{print $1}'
}

test_absent_section_uses_builtin_defaults() {
  local name="an absent section keeps the built-in sensitive paths"
  local dir out
  dir="$(mktemp -d)"; doc_diff_under_auth "$dir/diff.md"
  printf 'x\n' > "$dir/cfg.md"
  out="$(classify_with "$dir" "$dir/cfg.md")"
  rm -rf "$dir"
  [ "$out" != "trivial" ] && log_pass "$name" || log_fail "$name (got $out)"
}

test_commented_section_still_uses_defaults() {
  local name="a section with only comments keeps the defaults — it means 'not customised'"
  local dir out
  dir="$(mktemp -d)"; doc_diff_under_auth "$dir/diff.md"
  printf '## Sensitive Paths\n# - auth/\n# - payment/\n' > "$dir/cfg.md"
  out="$(classify_with "$dir" "$dir/cfg.md")"
  rm -rf "$dir"
  # The regression: this used to yield trivial, silently switching protection off.
  [ "$out" != "trivial" ] && log_pass "$name" || log_fail "$name (got $out — protection is off)"
}

test_explicit_entries_are_honored() {
  local name="explicit entries replace the defaults"
  local dir out
  dir="$(mktemp -d)"; doc_diff_under_auth "$dir/diff.md"
  printf '## Sensitive Paths\n- auth/\n' > "$dir/cfg.md"
  out="$(classify_with "$dir" "$dir/cfg.md")"
  rm -rf "$dir"
  [ "$out" != "trivial" ] && log_pass "$name" || log_fail "$name (got $out)"
}

test_unrelated_entries_do_not_protect_auth() {
  local name="entries that do not match leave the change trivial"
  local dir out
  dir="$(mktemp -d)"; doc_diff_under_auth "$dir/diff.md"
  printf '## Sensitive Paths\n- billing/\n' > "$dir/cfg.md"
  out="$(classify_with "$dir" "$dir/cfg.md")"
  rm -rf "$dir"
  [ "$out" = "trivial" ] && log_pass "$name" || log_fail "$name (got $out)"
}

test_none_disables_explicitly() {
  local name="'- none' is the explicit, deliberate way to turn the protection off"
  local dir out
  dir="$(mktemp -d)"; doc_diff_under_auth "$dir/diff.md"
  printf '## Sensitive Paths\n- none\n' > "$dir/cfg.md"
  out="$(classify_with "$dir" "$dir/cfg.md")"
  rm -rf "$dir"
  [ "$out" = "trivial" ] && log_pass "$name" || log_fail "$name (got $out)"
}

test_init_writes_the_section() {
  local name="/ship:init writes the section, so a new project can discover it"
  if grep -q '^## Sensitive Paths' "$REPO_ROOT/src/skills/init/SKILL.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_description_matches_behavior() {
  local name="the documented behavior matches the code — it gates doc/config diffs, not all diffs"
  local init="$REPO_ROOT/src/skills/init/SKILL.md"
  # The old wording claimed it "forces normal classification even for trivial
  # diffs". It does no such thing: sensitive_path_count is consulted in exactly
  # one branch, the doc/config-only one.
  if grep -q 'doc/config-only change from classifying as trivial' "$init" \
    && ! grep -qi "force 'normal'" "$init"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_absent_section_uses_builtin_defaults
test_commented_section_still_uses_defaults
test_explicit_entries_are_honored
test_unrelated_entries_do_not_protect_auth
test_none_disables_explicitly
test_init_writes_the_section
test_description_matches_behavior

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
