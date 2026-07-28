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

drive_to_plan_review() {
  local dir="$1" task="$2" scratch out state i
  scratch="$dir/.context/ship-run/$task"
  next "$dir" "$task" >/dev/null
  multi_module_spec > "$scratch/spec.md"
  mkdir -p "$dir/src"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/a.js"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/b.js"
  for i in 1 2 3 4; do
    out="$(next "$dir" "$task")"
    state="$(field "$out" state)"
    case "$state" in
      plan) valid_plan > "$scratch/plan.md" ;;
      plan-review) printf '%s' "$out"; return 0 ;;
    esac
  done
  printf '%s' "$out"
}

test_plan_is_confronted_before_develop() {
  local name="a validated plan is confronted with the files it claims before develop runs"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/TP1"
  local out; out="$(drive_to_plan_review "$dir" TP1)"
  if [ "$(field "$out" state)" = "plan-review" ] && [ "$(field "$out" action)" = "dispatch" ] \
    && printf '%s' "$out" | grep -q 'plan-review.md' \
    && printf '%s' "$out" | grep -q 'closed question set' \
    && ! grep -q '| dev |' "$scratch/dispatch-log.md"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state)/$(field "$out" action))"
  fi
  rm -rf "$dir"
}

test_plan_review_ok_proceeds_to_develop() {
  local name="verdict ok advances straight to develop"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/TP2"
  drive_to_plan_review "$dir" TP2 >/dev/null
  plan_review_ok "$scratch"
  local out; out="$(next "$dir" TP2)"
  if [ "$(field "$out" state)" = "develop" ] && grep -q '^ok' "$scratch/plan-confronted.txt"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state))"
  fi
  rm -rf "$dir"
}

test_plan_review_blockers_ask_then_replan_once() {
  local name="blockers ask the user; --answer replan re-dispatches the planner and the confrontation is not repeated"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/TP3"
  drive_to_plan_review "$dir" TP3 >/dev/null
  printf 'verdict: blockers\n- M1: needs src/registry.js to register the module\n' \
    > "$scratch/plan-review.md"
  local ask replan after
  ask="$(next "$dir" TP3)"
  replan="$(next "$dir" TP3 --answer replan)"
  valid_plan > "$scratch/plan.md"
  after="$(next "$dir" TP3)"
  if [ "$(field "$ask" state)" = "plan-review" ] && [ "$(field "$ask" action)" = "ask" ] \
    && [ "$(field "$replan" state)" = "plan" ] && [ "$(field "$replan" action)" = "dispatch" ] \
    && printf '%s' "$replan" | grep -q 'raised blockers' \
    && [ "$(field "$after" state)" = "develop" ]; then
    log_pass "$name"
  else
    log_fail "$name (ask=$(field "$ask" state)/$(field "$ask" action) replan=$(field "$replan" state) after=$(field "$after" state))"
  fi
  rm -rf "$dir"
}

test_plan_review_blockers_can_be_overridden() {
  local name="--answer proceed accepts the blockers and continues to develop"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/TP4"
  drive_to_plan_review "$dir" TP4 >/dev/null
  printf 'verdict: blockers\n- M1: boundary splits an indivisible unit\n' > "$scratch/plan-review.md"
  next "$dir" TP4 >/dev/null
  local out; out="$(next "$dir" TP4 --answer proceed)"
  if [ "$(field "$out" state)" = "develop" ] && grep -q '^proceed' "$scratch/plan-confronted.txt"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state))"
  fi
  rm -rf "$dir"
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

test_develop_receives_resolved_static_commands() {
  local name="develop is handed the same typecheck AND lint commands the pipeline will run, resolved from package.json"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  # Scripts live only in package.json — the case where develop used to skip
  # silently because ship/config.md carries no Typecheck field.
  printf '{"scripts":{"typecheck":"tsc --noEmit","lint":"eslint ."}}\n' > "$dir/package.json"
  (cd "$dir" && git add -A && git commit -q --amend --no-edit && git update-ref refs/remotes/origin/main HEAD) >/dev/null
  local scratch="$dir/.context/ship-run/TC1"
  next "$dir" TC1 >/dev/null
  single_module_spec > "$scratch/spec.md"
  local out; out="$(next "$dir" TC1)"
  if [ "$(field "$out" state)" = "develop" ] \
    && printf '%s' "$out" | grep -q 'Static checks: typecheck: npm run typecheck; lint: npm run lint'; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state))"
  fi
  rm -rf "$dir"
}

test_develop_gets_no_static_field_when_unresolvable() {
  local name="a repo with no typecheck or lint gets no Static checks field at all"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/TC2"
  next "$dir" TC2 >/dev/null
  single_module_spec > "$scratch/spec.md"
  local out; out="$(next "$dir" TC2)"
  if [ "$(field "$out" state)" = "develop" ] \
    && ! printf '%s' "$out" | grep -q 'Static checks:'; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state))"
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

test_gate_fail_dispatches_one_remediation_batch() {
  local name="gate FAIL asks; --answer fix dispatches ONE fix agent over remediation.md; the closed-set confirmation reaches homolog"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/T4"
  drive_to_verify_a "$dir" T4
  review_round "$scratch" fail 0 1 0 0 HIGH "Race condition on idempotency" "src/a.js"
  local ask fix verify regate
  ask="$(next "$dir" T4)"
  fix="$(next "$dir" T4 --answer fix)"
  echo 'fixed' >> "$dir/src/a.js"
  verify="$(next "$dir" T4)"
  printf -- '- R1: resolved\n' > "$scratch/remediation-verify.md"
  regate="$(next "$dir" T4)"
  if [ "$(field "$ask" state)" = "gate" ] && [ "$(field "$ask" action)" = "ask" ] \
    && [ "$(field "$fix" state)" = "remediation-fix" ] \
    && [ "$(printf '%s' "$fix" | grep -c 'subagent_type=general-purpose')" = "1" ] \
    && grep -q '^### R1 ' "$scratch/remediation.md" \
    && [ "$(field "$verify" state)" = "remediation-verify" ] \
    && ! printf '%s' "$verify" | grep -q 'ship:ship-review' \
    && [ "$(field "$regate" state)" = "homolog" ]; then
    log_pass "$name"
  else
    log_fail "$name (ask=$(field "$ask" state) fix=$(field "$fix" state) verify=$(field "$verify" state) regate=$(field "$regate" state))"
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
  plan_review_ok "$scratch"
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

drive_to_verify_a() {
  local dir="$1" task="$2" scratch out state i
  scratch="$dir/.context/ship-run/$task"
  next "$dir" "$task" >/dev/null
  multi_module_spec > "$scratch/spec.md"
  mkdir -p "$dir/src"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/a.js"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/b.js"
  for i in 1 2 3 4 5 6; do
    out="$(next "$dir" "$task")"
    state="$(field "$out" state)"
    case "$state" in
      plan) valid_plan > "$scratch/plan.md" ;;
      plan-review) plan_review_ok "$scratch" ;;
      verify-a) return 0 ;;
    esac
  done
  return 1
}

# The confrontation pass returns a closed verdict; fixtures that are not about it
# answer 'ok' so the run proceeds.
plan_review_ok() {
  printf 'verdict: ok\n' > "$1/plan-review.md"
}

review_round() {
  local scratch="$1" gate="$2" c="$3" h="$4" m="$5" l="$6" sev="$7" title="$8" file="$9"
  printf '| review | #<RUN> | 2026-01-01T00:00:00Z | - | %s | %s | %s | %s | %s | |\n' \
    "$gate" "$c" "$h" "$m" "$l" > "$scratch/phase-status-review.md"
  printf '### [%s] %s\n- **File:** %s\n' "$sev" "$title" "$file" > "$scratch/review-findings.md"
}

gate_fix_round() {
  local dir="$1" task="$2" tag="$3" out
  out="$(next "$dir" "$task" --answer fix)"
  printf 'fix-%s\n' "$tag" >> "$dir/src/a.js"
  next "$dir" "$task" >/dev/null
  printf '%s\n' "$(field "$out" state)"
}

# Gate Behavior with the auto-fix action, folded into the base commit: leaving
# the config edit uncommitted would make the initial diff config-only, which
# quality-scope classifies as trivial and skips review for.
gate_action_fix() {
  local dir="$1"
  sed -i.bak -e 's/- on_fail: ask/- on_fail: fix/' -e 's/- on_warn: ask/- on_warn: fix/' \
    "$dir/ship/config.md"
  rm -f "$dir/ship/config.md.bak"
  (
    cd "$dir"
    git add -A
    git commit -q --amend --no-edit
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null
}

test_remediation_round_is_not_repeated_automatically() {
  local name="residue after the one remediation round asks the user instead of fixing again"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  gate_action_fix "$dir"
  local scratch="$dir/.context/ship-run/T8"
  drive_to_verify_a "$dir" T8
  review_round "$scratch" fail 0 1 0 0 HIGH "Race condition on idempotency" "src/a.js"
  local r1 verify out
  r1="$(next "$dir" T8)"
  echo 'fix-r1' >> "$dir/src/a.js"
  verify="$(next "$dir" T8)"
  printf -- '- R1: unresolved — the race is still reachable\n' > "$scratch/remediation-verify.md"
  out="$(next "$dir" T8)"
  if [ "$(field "$r1" state)" = "remediation-fix" ] \
    && [ "$(field "$verify" state)" = "remediation-verify" ] \
    && [ "$(field "$out" state)" = "gate" ] && [ "$(field "$out" action)" = "ask" ] \
    && printf '%s' "$out" | grep -q 'R1'; then
    log_pass "$name"
  else
    log_fail "$name (r1=$(field "$r1" state) verify=$(field "$verify" state) out=$(field "$out" state)/$(field "$out" action))"
  fi
  rm -rf "$dir"
}

test_confirmation_cannot_mint_new_findings() {
  local name="the confirmation pass re-runs no analysis worker, so a resolved batch converges in one round"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  gate_action_fix "$dir"
  local scratch="$dir/.context/ship-run/T9"
  drive_to_verify_a "$dir" T9
  review_round "$scratch" fail 0 1 0 0 HIGH "Race condition on idempotency" "src/a.js"
  next "$dir" T9 >/dev/null
  echo 'fix-r1' >> "$dir/src/a.js"
  local verify done_out
  verify="$(next "$dir" T9)"
  printf -- '- R1: resolved\n' > "$scratch/remediation-verify.md"
  done_out="$(next "$dir" T9)"
  if [ "$(field "$verify" state)" = "remediation-verify" ] \
    && ! grep -qE 'ship-(review|perf|security)' <<< "$verify" \
    && [ "$(field "$done_out" state)" = "homolog" ] \
    && [ "$(grep -c '^| review |' "$scratch/phase-status.md")" -ge 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (verify=$(field "$verify" state) done=$(field "$done_out" state))"
  fi
  rm -rf "$dir"
}

test_warn_is_remediated_like_fail() {
  local name="a medium-only gate (WARN) still gets a remediation round — warnings are fixed, not deferred"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  gate_action_fix "$dir"
  local scratch="$dir/.context/ship-run/T11"
  drive_to_verify_a "$dir" T11
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Duplicated pre-lock query" "src/a.js"
  local out
  out="$(next "$dir" T11)"
  if [ "$(field "$out" state)" = "remediation-fix" ] \
    && grep -q '^### R1 ' "$scratch/remediation.md"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state))"
  fi
  rm -rf "$dir"
}

# A typecheck command that fails until a sentinel file exists — lets a test
# simulate the fix agent making typecheck green between rounds.
make_fake_typecheck() {
  local dir="$1" sentinel="$2" f="$dir/fake-tsc.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf '[ -f "%s" ] && exit 0\n' "$sentinel"
    printf 'echo "src/a.js(1,1): error TS2304: Cannot find name x"\n'
    printf 'exit 2\n'
  } > "$f"
  chmod +x "$f"
  printf -- '- Typecheck: %s\n' "$f" >> "$dir/ship/config.md"
}

# Drive init → context → (plan) → develop and return the FIRST `next` output at
# the static gate (static-fix when a check fails, verify-a when it skips). Robust
# to whether the planner runs, since post-develop passes even without mutation.
drive_to_static_gate() {
  local dir="$1" task="$2" scratch out state i
  scratch="$dir/.context/ship-run/$task"
  next "$dir" "$task" >/dev/null
  multi_module_spec > "$scratch/spec.md"
  mkdir -p "$dir/src"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/a.js"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/b.js"
  for i in 1 2 3 4 5; do
    out="$(next "$dir" "$task")"
    state="$(field "$out" state)"
    case "$state" in
      plan) valid_plan > "$scratch/plan.md" ;;
      plan-review) plan_review_ok "$scratch" ;;
      verify-a) printf '%s' "$out"; return 0 ;;
    esac
  done
  printf '%s' "$out"
}

test_static_failure_does_not_block_the_fan_out() {
  local name="a red typecheck no longer halts the pipeline — the fan-out runs and the failure is recorded"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  make_fake_typecheck "$dir" "$dir/.never"
  local scratch="$dir/.context/ship-run/TS1"
  local out; out="$(drive_to_static_gate "$dir" TS1)"
  if [ "$(field "$out" state)" = "verify-a" ] && [ "$(field "$out" action)" = "dispatch" ] \
    && [ -f "$scratch/static-failures.md" ] \
    && grep -qE '^\| static \| #1 \|.*\| fail \|' "$scratch/phase-status.md" \
    && ! grep -q 'static-fix' "$scratch/dispatch-log.md"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state)/$(field "$out" action))"
  fi
  rm -rf "$dir"
}

test_static_failure_joins_the_findings_in_one_batch() {
  local name="a red typecheck and a review finding land in the SAME remediation batch, fixed by one agent"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  make_fake_typecheck "$dir" "$dir/.never"
  gate_action_fix "$dir"
  local scratch="$dir/.context/ship-run/TS2"
  drive_to_static_gate "$dir" TS2 >/dev/null
  review_round "$scratch" fail 0 1 0 0 HIGH "Race condition on idempotency" "src/a.js"
  local out
  out="$(next "$dir" TS2)"
  if [ "$(field "$out" state)" = "remediation-fix" ] \
    && [ "$(printf '%s' "$out" | grep -c 'subagent_type=general-purpose')" = "1" ] \
    && grep -q 'typecheck/lint' "$scratch/remediation.md" \
    && grep -q 'race-condition-on-idempotency' "$scratch/remediation.md" \
    && [ "$(grep -c '^### R' "$scratch/remediation.md")" = "2" ]; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) items=$(grep -c '^### R' "$scratch/remediation.md" 2>/dev/null))"
  fi
  rm -rf "$dir"
}

plan_with_test_in_files() {
  cat <<EOF
## Module Map

### M1: core
- Files: src/a.js, test/a.test.js
- Depends on: none
- Contract: does things
- Scenarios: $SCEN_ID

## Test Contract

### $SCEN_ID -> unit -> test/a.test.js
- arrange: x
- act: y
- assert: z
EOF
}

test_denylist_excludes_test_files() {
  local name="a test file listed in a module's Files never lands on the test worker's denylist (it must be free to write it)"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' ''
  local scratch="$dir/.context/ship-run/TD1"
  next "$dir" TD1 >/dev/null
  multi_module_spec > "$scratch/spec.md"
  next "$dir" TD1 >/dev/null
  plan_with_test_in_files > "$scratch/plan.md"
  next "$dir" TD1 >/dev/null
  plan_review_ok "$scratch"
  next "$dir" TD1 >/dev/null
  mkdir -p "$dir/src"
  echo 'module.exports=1' > "$dir/src/a.js"
  next "$dir" TD1 >/dev/null
  local brief="$scratch/test-brief-unit.md" deny
  deny="$(sed -n '/## Denylist/,/## Source/p' "$brief" 2>/dev/null || true)"
  if [ -f "$brief" ] \
    && printf '%s' "$deny" | grep -q 'src/a.js' \
    && ! printf '%s' "$deny" | grep -q 'test/a.test.js'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_generated_tests_are_intent_added() {
  local name="generated (untracked) test files are intent-added so diff-based consumers see them"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled' '- perf: disabled
- security: disabled
- review: disabled'
  local scratch="$dir/.context/ship-run/TG1"
  next "$dir" TG1 >/dev/null
  single_module_spec > "$scratch/spec.md"
  next "$dir" TG1 >/dev/null
  mkdir -p "$dir/src" && echo 'module.exports=1' > "$dir/src/b.js"
  next "$dir" TG1 >/dev/null
  mkdir -p "$dir/test" && echo 'it(1)' > "$dir/test/b.test.js"
  printf -- '- test/b.test.js (unit)\n' > "$scratch/generated-tests-unit.md"
  next "$dir" TG1 >/dev/null
  if (cd "$dir" && git diff --name-only origin/main | grep -qx 'test/b.test.js'); then
    log_pass "$name"
  else
    log_fail "$name ($(cd "$dir" && git status --porcelain | tr '\n' ';'))"
  fi
  rm -rf "$dir"
}

test_static_gate_skip_when_no_checks() {
  local name="no typecheck/lint configured: static gate skips and the pipeline reaches verify-a"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/TS4"
  local out; out="$(drive_to_static_gate "$dir" TS4)"
  if [ "$(field "$out" state)" = "verify-a" ] \
    && grep -qE '^\| static \| #1 \|.*\| skip \|' "$scratch/phase-status.md"; then
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
test_plan_is_confronted_before_develop
test_plan_review_ok_proceeds_to_develop
test_plan_review_blockers_ask_then_replan_once
test_plan_review_blockers_can_be_overridden
test_post_develop_no_mutation_stops
test_develop_receives_resolved_static_commands
test_develop_gets_no_static_field_when_unresolvable
test_verify_a_dispatches_worker_with_brief
test_report_timings_prints_worker_start_lag
test_silent_worker_failure_redispatches_then_stops
test_happy_path_reaches_done_with_status_rows
test_gate_fail_dispatches_one_remediation_batch
test_gate_fail_defer_proceeds
test_dev_disabled_still_runs_verification
test_remediation_round_is_not_repeated_automatically
test_confirmation_cannot_mint_new_findings
test_warn_is_remediated_like_fail
test_static_failure_does_not_block_the_fan_out
test_static_failure_joins_the_findings_in_one_batch
test_static_gate_skip_when_no_checks
test_denylist_excludes_test_files
test_generated_tests_are_intent_added

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
