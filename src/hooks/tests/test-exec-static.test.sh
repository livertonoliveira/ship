#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_EXEC="$SCRIPT_DIR/../test-exec.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A repo whose typecheck/lint live only in package.json — the resolution path
# develop used to miss, because it read `ship/config.md → Typecheck` and nothing
# else.
setup_pkg_repo() {
  local dir="$1" tc_exit="${2:-0}" lint_exit="${3:-0}"
  mkdir -p "$dir/scratch"
  printf '# Config\n\n- Artifact language: en\n' > "$dir/config.md"
  {
    printf '#!/usr/bin/env bash\necho "src/a.ts(1,1): error TS2304"\nexit %s\n' "$tc_exit"
  } > "$dir/tc.sh"
  {
    printf '#!/usr/bin/env bash\necho "src/a.ts:1 lint error"\nexit %s\n' "$lint_exit"
  } > "$dir/lint.sh"
  chmod +x "$dir/tc.sh" "$dir/lint.sh"
  printf '{"scripts":{"typecheck":"true","lint":"true"}}\n' > "$dir/package.json"
}




test_static_only_records_individual_exits() {
  local name="--static-only records the real per-check exit codes"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf -- '- Typecheck: ./tc.sh\n- Lint: ./lint.sh\n' >> "$d/config.md"
  # tc.sh exits 0, lint.sh exits 0 by default; make typecheck red only.
  printf '#!/usr/bin/env bash\necho "TS2304"\nexit 2\n' > "$d/tc.sh"
  chmod +x "$d/tc.sh"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 1 ] \
    && grep -qx 'typecheck=2' "$d/scratch/static-exits.txt" \
    && grep -qx 'lint=0' "$d/scratch/static-exits.txt"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc exits=$(cat "$d/scratch/static-exits.txt" 2>/dev/null | tr '\n' ' '))"
  fi
  rm -rf "$d"
}

test_full_run_carries_forward_a_red_typecheck() {
  local name="a full run after a red static skips the suite instead of assuming green"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf -- '- Typecheck: ./tc.sh\n- Lint: ./lint.sh\n- Test Framework: ./suite.sh\n' >> "$d/config.md"
  printf '#!/usr/bin/env bash\necho "TS2304"\nexit 2\n' > "$d/tc.sh"
  printf '#!/usr/bin/env bash\necho "SUITE RAN"\nexit 0\n' > "$d/suite.sh"
  chmod +x "$d/tc.sh" "$d/suite.sh"
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || true
  touch "$d/scratch/static-exec-done.txt"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 1 ] \
    && grep -q 'Test suite not run' "$d/scratch/test-failures.md" \
    && ! grep -q 'SUITE RAN' "$d/scratch/test-failures.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc report=$(head -20 "$d/scratch/test-failures.md" 2>/dev/null | tr '\n' ' '))"
  fi
  rm -rf "$d"
}

test_unrecognized_test_framework_fails_with_actionable_message() {
  local name="a Test Framework value that resolves to no executable command fails clearly instead of a bare 'command not found'"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf -- '- Test Framework: node:assert (custom runner)\n' >> "$d/config.md"
  local out rc=0
  out="$(cd "$d" && bash "$TEST_EXEC" scratch --config config.md 2>&1)" || rc=$?
  if [ "$rc" -eq 2 ] \
    && printf '%s' "$out" | grep -qF "Test Framework 'node:assert (custom runner)' is not a known runner" \
    && printf '%s' "$out" | grep -qF "fix Test Framework in stack.md or ship/config.md"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$d"
}

# Lint scoping: develop-touched-files.txt is the verified footprint, and the
# whole-project lint used to be the slowest step of a run.
test_lint_placeholder_receives_only_existing_touched_files() {
  local name="a Lint command with {files} receives the touched files that still exist, nothing else"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf -- '- Lint: ./lint.sh {files}\n' >> "$d/config.md"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > lint-args.txt\nexit 0\n' > "$d/lint.sh"
  chmod +x "$d/lint.sh"
  mkdir -p "$d/src"
  : > "$d/src/a.ts"; : > "$d/src/b c.ts"
  printf 'src/a.ts\nsrc/gone.ts\nsrc/b c.ts\n' > "$d/scratch/develop-touched-files.txt"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$d/lint-args.txt" | tr '\n' '|')" = "src/a.ts|src/b c.ts|" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc args=$(cat "$d/lint-args.txt" 2>/dev/null | tr '\n' '|'))"
  fi
  rm -rf "$d"
}

test_eslint_package_script_is_scoped_to_touched_files() {
  local name="a package.json eslint script keeps its flags, drops its globs and lints only touched files of a matching extension"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf '{"scripts":{"lint":"eslint \\"{src,test}/**/*.ts\\" --fix --max-warnings 0"}}\n' > "$d/package.json"
  mkdir -p "$d/node_modules/.bin" "$d/src"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > lint-args.txt\nexit 0\n' > "$d/node_modules/.bin/eslint"
  chmod +x "$d/node_modules/.bin/eslint"
  : > "$d/src/a.ts"; : > "$d/src/b.js"; : > "$d/README.md"
  printf 'src/a.ts\nsrc/b.js\nREADME.md\n' > "$d/scratch/develop-touched-files.txt"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$d/lint-args.txt" | tr '\n' '|')" = "--fix|--max-warnings|0|src/a.ts|" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc args=$(cat "$d/lint-args.txt" 2>/dev/null | tr '\n' '|'))"
  fi
  rm -rf "$d"
}

test_lint_runs_unscoped_without_a_footprint() {
  local name="no develop footprint: the configured Lint command runs exactly as written"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf -- '- Lint: ./lint.sh --all\n' >> "$d/config.md"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > lint-args.txt\nexit 0\n' > "$d/lint.sh"
  chmod +x "$d/lint.sh"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --static-only >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$d/lint-args.txt" | tr '\n' '|')" = "--all|" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc args=$(cat "$d/lint-args.txt" 2>/dev/null | tr '\n' '|'))"
  fi
  rm -rf "$d"
}

test_static_only_records_individual_exits
test_lint_placeholder_receives_only_existing_touched_files
test_eslint_package_script_is_scoped_to_touched_files
test_lint_runs_unscoped_without_a_footprint
test_full_run_carries_forward_a_red_typecheck
test_unrecognized_test_framework_fails_with_actionable_message

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
