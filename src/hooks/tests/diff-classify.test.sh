#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_CLASSIFY_SCRIPT="$SCRIPT_DIR/../diff-classify.sh"

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

append_changed_lines() {
  local out="$1" count="$2" i=0
  while [ "$i" -lt "$count" ]; do
    printf '+line %s\n' "$i" >> "$out"
    i=$((i + 1))
  done
}

make_diff_fixture() {
  local dir="$1" file="$2" lines="$3"
  shift 3
  local extra=("$@")
  {
    printf '%s\n' "diff --git a/$file b/$file"
    printf '%s\n' "--- a/$file"
    printf '%s\n' "+++ b/$file"
    append_changed_lines /dev/stdout "$lines"
    if [ "${#extra[@]}" -gt 0 ]; then
      printf '%s\n' "${extra[@]}"
    fi
  } >> "$dir"
}

test_typical_diff_classifies_as_normal() {
  local name="a diff with 300 changed lines across 4 code files and no new-endpoint patterns classifies as normal"
  local dir out diff
  dir="$(mktemp -d)"
  diff="$dir/diff.md"
  out="$dir/out.txt"
  : > "$diff"
  make_diff_fixture "$diff" "src/a.ts" 75
  make_diff_fixture "$diff" "src/b.ts" 75
  make_diff_fixture "$diff" "src/c.ts" 75
  make_diff_fixture "$diff" "src/d.ts" 75

  local stdout_output rc=0
  stdout_output="$(bash "$DIFF_CLASSIFY_SCRIPT" "$diff" "$out")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! grep -q '^normal$' "$out"; then
    log_fail "$name (output file did not contain normal: $(cat "$out"))"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s\n' "$stdout_output" | grep -qE '^normal \(.+\)$'; then
    log_fail "$name (stdout did not match 'normal (...)': $stdout_output)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_class_rule() {
  local case_name="$1" expected_class="$2"
  shift 2
  local name="a diff matching the $case_name rule classifies as $expected_class"
  local dir out diff
  dir="$(mktemp -d)"
  diff="$dir/diff.md"
  out="$dir/out.txt"
  : > "$diff"

  case "$case_name" in
    trivial)
      make_diff_fixture "$diff" "README.md" 10
      make_diff_fixture "$diff" "config.json" 10
      ;;
    large)
      make_diff_fixture "$diff" "src/big.ts" 1200
      ;;
    minor)
      make_diff_fixture "$diff" "src/small.ts" 48
      ;;
    normal_endpoint)
      make_diff_fixture "$diff" "src/api.ts" 78 "+  @Post('/users')" "+  handle()"
      ;;
  esac

  local rc=0
  bash "$DIFF_CLASSIFY_SCRIPT" "$diff" "$out" > /dev/null || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! grep -q "^${expected_class}\$" "$out"; then
    log_fail "$name (output file did not contain $expected_class: $(cat "$out"))"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_missing_diff_file_fails() {
  local name="running with a missing diff file exits non-zero and reports the missing path on stderr"
  local dir out missing
  dir="$(mktemp -d)"
  out="$dir/out.txt"
  missing="$dir/caminho/inexistente.md"

  local rc=0
  local stderr_output
  stderr_output="$(bash "$DIFF_CLASSIFY_SCRIPT" "$missing" "$out" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    log_fail "$name (exit code was 0)"
    rm -rf "$dir"
    return
  fi

  if ! printf '%s' "$stderr_output" | grep -qF "$missing"; then
    log_fail "$name (stderr did not mention missing file: $stderr_output)"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_sensitive_paths_override_replaces_defaults() {
  local name="a Sensitive Paths config override replaces the default sensitive prefixes"
  local dir cfg diff_auth diff_internal out_auth out_internal
  dir="$(mktemp -d)"
  cfg="$dir/config.md"
  {
    printf '%s\n' "## Sensitive Paths"
    printf '%s\n' "# - auth/"
    printf '%s\n' "- internal/"
  } > "$cfg"

  diff_auth="$dir/auth-diff.md"
  : > "$diff_auth"
  make_diff_fixture "$diff_auth" "auth/guard.ts" 20

  diff_internal="$dir/internal-diff.md"
  : > "$diff_internal"
  make_diff_fixture "$diff_internal" "internal/core.ts" 20

  out_auth="$dir/out-auth.txt"
  out_internal="$dir/out-internal.txt"

  local rc=0
  bash "$DIFF_CLASSIFY_SCRIPT" "$diff_auth" "$out_auth" --config "$cfg" > /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (auth/guard.ts run exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! grep -q '^minor$' "$out_auth"; then
    log_fail "$name (auth/guard.ts expected minor, got $(cat "$out_auth"))"
    rm -rf "$dir"
    return
  fi

  rc=0
  bash "$DIFF_CLASSIFY_SCRIPT" "$diff_internal" "$out_internal" --config "$cfg" > /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (internal/core.ts run exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  local diff_auth_doc diff_internal_doc out_auth_doc out_internal_doc
  diff_auth_doc="$dir/auth-doc-diff.md"
  : > "$diff_auth_doc"
  make_diff_fixture "$diff_auth_doc" "auth/README.md" 20

  diff_internal_doc="$dir/internal-doc-diff.md"
  : > "$diff_internal_doc"
  make_diff_fixture "$diff_internal_doc" "internal/README.md" 20

  out_auth_doc="$dir/out-auth-doc.txt"
  out_internal_doc="$dir/out-internal-doc.txt"

  rc=0
  bash "$DIFF_CLASSIFY_SCRIPT" "$diff_auth_doc" "$out_auth_doc" --config "$cfg" > /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (auth/README.md run exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if ! grep -q '^trivial$' "$out_auth_doc"; then
    log_fail "$name (auth/README.md expected trivial since auth/ is no longer sensitive, got $(cat "$out_auth_doc"))"
    rm -rf "$dir"
    return
  fi

  rc=0
  bash "$DIFF_CLASSIFY_SCRIPT" "$diff_internal_doc" "$out_internal_doc" --config "$cfg" > /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$name (internal/README.md run exit code was $rc)"
    rm -rf "$dir"
    return
  fi

  if grep -q '^trivial$' "$out_internal_doc"; then
    log_fail "$name (internal/README.md should not be trivial since internal/ is the active sensitive prefix, got $(cat "$out_internal_doc"))"
    rm -rf "$dir"
    return
  fi

  log_pass "$name"
  rm -rf "$dir"
}

test_typical_diff_classifies_as_normal
test_class_rule "trivial" "trivial"
test_class_rule "large" "large"
test_class_rule "minor" "minor"
test_class_rule "normal_endpoint" "normal"
test_missing_diff_file_fails
test_sensitive_paths_override_replaces_defaults

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
