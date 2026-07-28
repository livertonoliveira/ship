#!/usr/bin/env bash

# A test file only produces coverage if something runs it. Two ways it silently
# does not, both seen on the same live run: the plan declares a layer the file's
# own naming contradicts, so it lands under a runner config that cannot see it;
# and the plan routes a scenario to a layer the project disabled, so no worker is
# ever scoped to it. Both ended with a test on disk, never executed, gate green.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TL="$SCRIPT_DIR/../test-layer.sh"
PV="$SCRIPT_DIR/../plan-validate.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

classify() { bash "$TL" classify "$1" | cut -f1; }

expect_layer() {
  local path="$1" want="$2" got
  got="$(classify "$path")"
  if [ "$got" = "$want" ]; then
    log_pass "$path classifies as $want"
  else
    log_fail "$path classifies as $want (got $got)"
  fi
}

test_classification() {
  expect_layer "test/e2e/cash-flow.e2e-spec.ts" e2e
  expect_layer "test/unit/presentation/cash-flow.controller.spec.ts" unit
  expect_layer "test/integration/use-cases/create-transfer.spec.ts" integration
  expect_layer "tests/e2e/checkout.cy.js" e2e
  expect_layer "src/foo/bar.integration.test.ts" integration
  # No layer marker anywhere in the path: guessing one would be worse than
  # admitting ignorance, since every consumer treats unknown as "do not reroute".
  expect_layer "test/presentation/controllers/cash-flow.controller.spec.ts" unknown
  expect_layer "src/app.ts" unknown
}

SCEN_ID="@S"'C-01'

write_plan() {
  local dir="$1" layer="$2" path="$3"
  cat > "$dir/plan.md" <<EOF
# Plan

## Modules
### M1: thing
- Files: src/a.js
- Depends on: none
- Scenarios: $SCEN_ID
- Contract: does a thing

## Test Contract

### $SCEN_ID -> $layer -> $path
- arrange: x
- act: y
- assert: z

## Order
- M1
EOF
}

write_config() {
  local dir="$1" scope="$2"
  cat > "$dir/config.md" <<EOF
# Config

## Test Scope
$scope
EOF
}

test_layer_path_contradiction_rejected() {
  local name="a slot whose path contradicts its declared layer is rejected"
  local dir out rc=0
  dir="$(mktemp -d)"
  # Exactly the live defect: declared integration, named .e2e-spec.ts, so it runs
  # only under the e2e config the integration command never loads.
  write_plan "$dir" integration "test/e2e/cash-flow.e2e-spec.ts"
  out="$(bash "$PV" "$dir/plan.md" 2>&1)" || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "contradiz a camada"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_agreeing_layer_and_path_accepted() {
  local name="a slot whose path agrees with its layer passes"
  local dir rc=0
  dir="$(mktemp -d)"
  write_plan "$dir" e2e "test/e2e/cash-flow.e2e-spec.ts"
  bash "$PV" "$dir/plan.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
}

test_unknown_path_never_contradicts() {
  local name="a path with no layer marker never contradicts the declared layer"
  local dir rc=0
  dir="$(mktemp -d)"
  write_plan "$dir" unit "test/a.test.js"
  bash "$PV" "$dir/plan.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
}

test_disabled_layer_rejected() {
  local name="a slot routed to a layer disabled in ## Test Scope is rejected"
  local dir out rc=0
  dir="$(mktemp -d)"
  write_plan "$dir" e2e "test/e2e/a.e2e-spec.ts"
  write_config "$dir" '- unit: enabled
- integration: enabled
- e2e: disabled'
  out="$(bash "$PV" "$dir/plan.md" --config "$dir/config.md" 2>&1)" || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "camada desabilitada"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_enabled_layer_accepted() {
  local name="a slot in an enabled layer passes the scope check"
  local dir rc=0
  dir="$(mktemp -d)"
  write_plan "$dir" e2e "test/e2e/a.e2e-spec.ts"
  write_config "$dir" '- unit: enabled
- integration: enabled
- e2e: enabled'
  bash "$PV" "$dir/plan.md" --config "$dir/config.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
}

test_whole_test_phase_off_skips_scope_check() {
  local name="with the whole test phase disabled, layer scope is moot and not enforced"
  local dir rc=0
  dir="$(mktemp -d)"
  write_plan "$dir" e2e "test/e2e/a.e2e-spec.ts"
  cat > "$dir/config.md" <<'EOF'
# Config

## Pipeline Phases
- test: disabled

## Test Scope
- unit: disabled
- integration: disabled
- e2e: disabled
EOF
  bash "$PV" "$dir/plan.md" --config "$dir/config.md" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  if [ "$rc" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
}

test_classification
test_layer_path_contradiction_rejected
test_agreeing_layer_and_path_accepted
test_unknown_path_never_contradicts
test_disabled_layer_rejected
test_enabled_layer_accepted
test_whole_test_phase_off_skips_scope_check

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
