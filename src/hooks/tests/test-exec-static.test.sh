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

test_print_static_resolves_from_package_json() {
  local name="--print-static resolves both commands from package.json without running them"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  local out rc=0
  out="$(cd "$d" && bash "$TEST_EXEC" scratch --config config.md --print-static)" || rc=$?
  if [ "$rc" -eq 0 ] \
    && printf '%s' "$out" | grep -qx 'typecheck=npm run typecheck' \
    && printf '%s' "$out" | grep -qx 'lint=npm run lint' \
    && [ ! -f "$d/scratch/phase-status-static.md" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$d"
}

test_print_static_prefers_explicit_config() {
  local name="--print-static prefers an explicit config field over the package.json probe"
  local d; d="$(mktemp -d)"
  setup_pkg_repo "$d"
  printf -- '- Typecheck: mypy .\n' >> "$d/config.md"
  local out
  out="$(cd "$d" && bash "$TEST_EXEC" scratch --config config.md --print-static)"
  if printf '%s' "$out" | grep -qx 'typecheck=mypy .'; then
    log_pass "$name"
  else
    log_fail "$name (out=$out)"
  fi
  rm -rf "$d"
}

test_print_static_exits_2_when_nothing_resolves() {
  local name="--print-static exits 2 when neither check resolves"
  local d; d="$(mktemp -d)"
  mkdir -p "$d/scratch"
  printf '# Config\n' > "$d/config.md"
  local rc=0
  (cd "$d" && bash "$TEST_EXEC" scratch --config config.md --print-static >/dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
  rm -rf "$d"
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

test_print_static_resolves_from_package_json
test_print_static_prefers_explicit_config
test_print_static_exits_2_when_nothing_resolves
test_static_only_records_individual_exits
test_full_run_carries_forward_a_red_typecheck

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
