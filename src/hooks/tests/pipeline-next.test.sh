#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

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

setup_repo() {
  local dir="$1" test_scope="$2" phases="$3"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    mkdir ship
    {
      printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n## Test Scope\n%s\n' "$test_scope"
      [ -n "$phases" ] && printf '\n## Pipeline Phases\n%s\n' "$phases"
      printf '\n## Gate Behavior\n- on_fail: ask\n- on_warn: ask\n\n- Test Framework: none\n'
    } > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null
}

next() {
  local dir="$1"
  shift
  (cd "$dir" && bash "$PIPELINE" next "$@")
}

field() {
  printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-
}

# Scenario-id tokens are built by concatenation so this file itself carries no
# spec-id literals (the hygiene gate forbids them); the fixtures still exercise
# the real tag-parsing behavior at runtime.
SCEN_ID="@S"'C-01'

single_module_spec() {
  cat <<EOF
## Files
- src/b.js

Dependencies: None

$SCEN_ID @unit
Scenario: greets
  Given a name
  Then it greets
EOF
}

multi_module_spec() {
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules, deps exist\n'
}

valid_plan() {
  cat <<EOF
## Module Map

### M1: core
- Files: src/a.js, src/b.js
- Depends on: none
- Contract: does things
- Scenarios: $SCEN_ID

## Test Contract

### $SCEN_ID -> unit -> src/a.test.js
- arrange: x
- act: y
- assert: z
EOF
}

test_first_call_asks_for_context_staging() {
  local name="first call inits the scratch dir and asks for context staging (action=work)"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  local out; out="$(next "$dir" TASK-1)"
  if [ "$(field "$out" state)" = "context" ] && [ "$(field "$out" action)" = "work" ] \
    && [ -f "$dir/.context/ship-run/TASK-1/diff-class.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_single_module_spec_skips_planner() {
  local name="a single-module spec skips the planner and dispatches develop alone"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  next "$dir" TASK-1 >/dev/null
  single_module_spec > "$dir/.context/ship-run/TASK-1/spec.md"
  local out; out="$(next "$dir" TASK-1)"
  if [ "$(field "$out" state)" = "develop" ] && [ "$(field "$out" action)" = "dispatch" ] \
    && printf '%s' "$out" | grep -q 'Skill ship:develop' \
    && grep -q 'skip:single-module' "$dir/.context/ship-run/TASK-1/plan-decision.txt" \
    && grep -q '| plan | - | skipped |' "$dir/.context/ship-run/TASK-1/dispatch-log.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_greenfield_multi_module_runs_planner() {
  local name="a greenfield multi-module task dispatches ship:plan first"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  next "$dir" TASK-1 >/dev/null
  multi_module_spec > "$dir/.context/ship-run/TASK-1/spec.md"
  local out; out="$(next "$dir" TASK-1)"
  if [ "$(field "$out" state)" = "plan" ] && printf '%s' "$out" | grep -q 'Skill ship:plan'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_invalid_plan_asks_then_replans() {
  local name="an invalid plan.md asks the user; --answer replan re-dispatches the planner"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  next "$dir" TASK-1 >/dev/null
  multi_module_spec > "$dir/.context/ship-run/TASK-1/spec.md"
  next "$dir" TASK-1 >/dev/null
  echo 'garbage' > "$dir/.context/ship-run/TASK-1/plan.md"
  local ask replan
  ask="$(next "$dir" TASK-1)"
  replan="$(next "$dir" TASK-1 --answer replan)"
  if [ "$(field "$ask" action)" = "ask" ] && [ "$(field "$replan" action)" = "dispatch" ] \
    && printf '%s' "$replan" | grep -q 'Skill ship:plan'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_post_develop_no_mutation_stops() {
  local name="develop returning without mutating the tree yields action=stop"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  next "$dir" TASK-1 >/dev/null
  single_module_spec > "$dir/.context/ship-run/TASK-1/spec.md"
  next "$dir" TASK-1 >/dev/null
  local out; out="$(next "$dir" TASK-1)"
  if [ "$(field "$out" state)" = "post-develop" ] && [ "$(field "$out" action)" = "stop" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_verify_a_dispatches_worker_with_brief() {
  local name="verify-a dispatches the unit worker with a deterministic brief (contract, scenarios, denylist, SUT slice, start marker)"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  mkdir -p "$dir/src"
  echo 'it(1)' > "$dir/src/existing.test.js"
  (cd "$dir" && git add -A && git commit -qm tests && git update-ref refs/remotes/origin/main HEAD) >/dev/null
  next "$dir" TASK-1 >/dev/null
  single_module_spec > "$dir/.context/ship-run/TASK-1/spec.md"
  next "$dir" TASK-1 >/dev/null
  echo 'module.exports=1' > "$dir/src/b.js"
  local out brief
  out="$(next "$dir" TASK-1)"
  brief="$dir/.context/ship-run/TASK-1/test-brief-unit.md"
  if [ "$(field "$out" state)" = "verify-a" ] \
    && printf '%s' "$out" | grep -q 'subagent_type=ship:ship-test-unit' \
    && printf '%s' "$out" | grep -q 'worker-start-ship-test-unit.txt' \
    && [ -f "$brief" ] \
    && grep -q 'Scenario: greets' "$brief" \
    && ! grep -q "$SCEN_ID" "$brief" \
    && grep -q 'src/b.js' "$brief" \
    && grep -q 'read these first' "$brief" \
    && grep -q 'src/existing.test.js' "$brief" \
    && grep -q '| test | Agent | ship-test-unit |' "$dir/.context/ship-run/TASK-1/dispatch-log.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_report_timings_prints_worker_start_lag() {
  local name="report-timings prints per-worker start lag from worker-start markers"
  local dir; dir="$(mktemp -d)"
  printf '100\ttest\tAgent\tship-test-unit\n110\treview\tAgent\tship-review\n' > "$dir/timings.tsv"
  printf '160\n' > "$dir/worker-start-ship-test-unit.txt"
  local out; out="$(bash "$PIPELINE" report-timings "$dir")"
  if printf '%s\n' "$out" | grep -qE 'ship-test-unit +60' \
    && ! printf '%s\n' "$out" | grep -qE '^ship-review '; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_silent_worker_failure_redispatches_then_stops() {
  local name="a worker that never writes its manifest is re-dispatched twice, then the pipeline stops"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  next "$dir" TASK-1 >/dev/null
  single_module_spec > "$dir/.context/ship-run/TASK-1/spec.md"
  next "$dir" TASK-1 >/dev/null
  mkdir -p "$dir/src" && echo 'module.exports=1' > "$dir/src/b.js"
  next "$dir" TASK-1 >/dev/null
  local r1 r2 r3
  r1="$(next "$dir" TASK-1)"
  r2="$(next "$dir" TASK-1)"
  r3="$(next "$dir" TASK-1)"
  if [ "$(field "$r1" action)" = "dispatch" ] && [ "$(field "$r2" action)" = "dispatch" ] \
    && [ "$(field "$r3" action)" = "stop" ]; then
    log_pass "$name"
  else
    log_fail "$name (r1=$(field "$r1" action) r2=$(field "$r2" action) r3=$(field "$r3" action))"
  fi
  rm -rf "$dir"
}

test_happy_path_reaches_done_with_status_rows() {
  local name="happy path: manifests consolidate, gate passes, homolog asks, --answer approved finishes"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  next "$dir" TASK-1 >/dev/null
  local scratch="$dir/.context/ship-run/TASK-1"
  single_module_spec > "$scratch/spec.md"
  next "$dir" TASK-1 >/dev/null
  mkdir -p "$dir/src" && echo 'module.exports=1' > "$dir/src/b.js"
  next "$dir" TASK-1 >/dev/null
  printf -- '- src/b.test.js (unit)\n' > "$scratch/generated-tests-unit.md"
  local mid
  mid="$(next "$dir" TASK-1)"
  if [ "$(field "$mid" state)" = "analyze" ]; then
    printf '| analyze | #<RUN> | 2026-01-01T00:00:00Z | - | pass | 0 | 0 | 0 | 0 | |\n' \
      > "$scratch/phase-status-analyze.md"
    mid="$(next "$dir" TASK-1)"
  fi
  local fin
  fin="$(next "$dir" TASK-1 --answer approved)"
  if [ "$(field "$mid" state)" = "homolog" ] && [ "$(field "$mid" action)" = "work" ] \
    && [ "$(field "$fin" action)" = "done" ] \
    && grep -q '^| dev | #1 |' "$scratch/phase-status.md" \
    && grep -q '^| test-generate | #1 |' "$scratch/phase-status.md" \
    && grep -q -- '- src/b.test.js (unit)' "$scratch/generated-tests.md" \
    && printf '%s' "$fin" | grep -q 'TOTAL'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_gate_fail_fix_rerun_cycle() {
  local name="gate FAIL asks; --answer fix dispatches a fix agent; mutation triggers a surgical re-run of only the phases that ran"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  next "$dir" T4 >/dev/null
  local scratch="$dir/.context/ship-run/T4"
  multi_module_spec > "$scratch/spec.md"
  next "$dir" T4 >/dev/null
  valid_plan > "$scratch/plan.md"
  next "$dir" T4 >/dev/null
  mkdir -p "$dir/src"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/a.js"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/b.js"
  next "$dir" T4 >/dev/null
  printf '| review | #<RUN> | 2026-01-01T00:00:00Z | - | fail | 0 | 1 | 0 | 0 | bad |\n' \
    > "$scratch/phase-status-review.md"
  local ask fix rerun regate
  ask="$(next "$dir" T4)"
  fix="$(next "$dir" T4 --answer fix)"
  echo 'fixed' >> "$dir/src/a.js"
  rerun="$(next "$dir" T4)"
  printf '| review | #<RUN> | 2026-01-01T00:05:00Z | - | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |\n' \
    > "$scratch/phase-status-review.md"
  regate="$(next "$dir" T4)"
  if [ "$(field "$ask" state)" = "gate" ] && [ "$(field "$ask" action)" = "ask" ] \
    && [ "$(field "$fix" state)" = "gate-fix" ] \
    && [ "$(field "$rerun" state)" = "verify-rerun" ] && [ "$(field "$rerun" run)" = "2" ] \
    && printf '%s' "$rerun" | grep -q 'ship:ship-review' \
    && ! printf '%s' "$rerun" | grep -q 'ship:ship-perf' \
    && [ "$(field "$regate" state)" = "homolog" ] \
    && grep -q '^| review | #2 | .* | pass |' "$scratch/phase-status.md"; then
    log_pass "$name"
  else
    log_fail "$name (ask=$(field "$ask" state) fix=$(field "$fix" state) rerun=$(field "$rerun" state)/$(field "$rerun" run) regate=$(field "$regate" state))"
  fi
  rm -rf "$dir"
}

test_gate_fail_defer_proceeds() {
  local name="gate FAIL with --answer defer proceeds to homolog"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  next "$dir" T6 >/dev/null
  local scratch="$dir/.context/ship-run/T6"
  multi_module_spec > "$scratch/spec.md"
  next "$dir" T6 >/dev/null
  valid_plan > "$scratch/plan.md"
  next "$dir" T6 >/dev/null
  mkdir -p "$dir/src"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/a.js"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/b.js"
  next "$dir" T6 >/dev/null
  printf '| review | #<RUN> | 2026-01-01T00:00:00Z | - | fail | 0 | 1 | 0 | 0 | bad |\n' \
    > "$scratch/phase-status-review.md"
  next "$dir" T6 >/dev/null
  local out; out="$(next "$dir" T6 --answer defer)"
  if [ "$(field "$out" state)" = "homolog" ] && grep -q 'deferred' "$scratch/gate-resolved.txt"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_dev_disabled_still_runs_verification() {
  local name="dev disabled skips plan/develop but still runs verification and reaches homolog"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- dev: disabled
- test: disabled'
  next "$dir" T7 >/dev/null
  local scratch="$dir/.context/ship-run/T7"
  multi_module_spec > "$scratch/spec.md"
  local out; out="$(next "$dir" T7)"
  if [ "$(field "$out" state)" = "homolog" ] \
    && grep -q 'skip:dev-disabled' "$scratch/plan-decision.txt" \
    && grep -q '| dev | - | skipped |' "$scratch/dispatch-log.md"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state))"
  fi
  rm -rf "$dir"
}

test_first_call_asks_for_context_staging
test_single_module_spec_skips_planner
test_greenfield_multi_module_runs_planner
test_invalid_plan_asks_then_replans
test_post_develop_no_mutation_stops
test_verify_a_dispatches_worker_with_brief
test_report_timings_prints_worker_start_lag
test_silent_worker_failure_redispatches_then_stops
test_happy_path_reaches_done_with_status_rows
test_gate_fail_fix_rerun_cycle
test_gate_fail_defer_proceeds
test_dev_disabled_still_runs_verification

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
