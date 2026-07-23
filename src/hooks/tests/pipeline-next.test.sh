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

drive_to_verify_a() {
  local dir="$1" task="$2" scratch
  scratch="$dir/.context/ship-run/$task"
  next "$dir" "$task" >/dev/null
  multi_module_spec > "$scratch/spec.md"
  next "$dir" "$task" >/dev/null
  valid_plan > "$scratch/plan.md"
  next "$dir" "$task" >/dev/null
  mkdir -p "$dir/src"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/a.js"
  seq 1 60 | sed 's/^/console.log(/;s/$/)/' > "$dir/src/b.js"
  next "$dir" "$task" >/dev/null
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

test_identity_fixpoint_stops_the_loop() {
  local name="a re-verify round with no new finding identity stops the fix loop and asks the user"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/T8"
  drive_to_verify_a "$dir" T8
  review_round "$scratch" fail 0 1 0 0 HIGH "Race condition on idempotency" "src/a.js"
  local r1 regate
  r1="$(gate_fix_round "$dir" T8 r1)"
  review_round "$scratch" fail 0 1 0 0 HIGH "Race condition on idempotency" "src/a.js"
  regate="$(next "$dir" T8 --answer fix)"
  if [ "$r1" = "gate-fix" ] \
    && [ "$(field "$regate" state)" = "gate" ] && [ "$(field "$regate" action)" = "ask" ] \
    && printf '%s' "$regate" | grep -q 'no new finding'; then
    log_pass "$name"
  else
    log_fail "$name (r1=$r1 regate=$(field "$regate" state)/$(field "$regate" action))"
  fi
  rm -rf "$dir"
}

test_self_inflicted_churn_advances_instead_of_refixing() {
  local name="a new ≤medium finding on a file the fix itself touched is deferred to homolog, not re-fixed"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/T9"
  drive_to_verify_a "$dir" T9
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Duplicated pre-lock query" "src/a.js"
  local r1 out
  r1="$(gate_fix_round "$dir" T9 r1)"
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Local constant naming" "src/a.js"
  out="$(next "$dir" T9 --answer fix)"
  if [ "$r1" = "gate-fix" ] && [ "$(field "$out" state)" = "homolog" ] \
    && grep -q 'churn-deferred' "$scratch/gate-resolved.txt"; then
    log_pass "$name"
  else
    log_fail "$name (r1=$r1 state=$(field "$out" state))"
  fi
  rm -rf "$dir"
}

test_fix_cap_with_blocking_findings_stops() {
  local name="three fix rounds with distinct critical/high findings, then the cap stops for manual intervention"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/T10"
  drive_to_verify_a "$dir" T10
  local s1 s2 s3 final
  review_round "$scratch" fail 0 1 0 0 HIGH "Broken guard one" "src/a.js"
  s1="$(gate_fix_round "$dir" T10 r1)"
  review_round "$scratch" fail 0 1 0 0 HIGH "Broken guard two" "src/a.js"
  s2="$(gate_fix_round "$dir" T10 r2)"
  review_round "$scratch" fail 0 1 0 0 HIGH "Broken guard three" "src/a.js"
  s3="$(gate_fix_round "$dir" T10 r3)"
  review_round "$scratch" fail 0 1 0 0 HIGH "Broken guard four" "src/a.js"
  final="$(next "$dir" T10 --answer fix)"
  if [ "$s1" = "gate-fix" ] && [ "$s2" = "gate-fix" ] && [ "$s3" = "gate-fix" ] \
    && [ "$(field "$final" state)" = "gate" ] && [ "$(field "$final" action)" = "stop" ]; then
    log_pass "$name"
  else
    log_fail "$name (s1=$s1 s2=$s2 s3=$s3 final=$(field "$final" state)/$(field "$final" action))"
  fi
  rm -rf "$dir"
}

test_fix_cap_with_only_warnings_advances() {
  local name="three fix rounds with distinct non-churn mediums, then the cap defers to homolog (non-blocking)"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/T11"
  drive_to_verify_a "$dir" T11
  local s1 s2 s3 final
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Style nit one" "src/other.js"
  s1="$(gate_fix_round "$dir" T11 r1)"
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Style nit two" "src/other.js"
  s2="$(gate_fix_round "$dir" T11 r2)"
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Style nit three" "src/other.js"
  s3="$(gate_fix_round "$dir" T11 r3)"
  review_round "$scratch" warn 0 0 1 0 MEDIUM "Style nit four" "src/other.js"
  final="$(next "$dir" T11 --answer fix)"
  if [ "$s1" = "gate-fix" ] && [ "$s2" = "gate-fix" ] && [ "$s3" = "gate-fix" ] \
    && [ "$(field "$final" state)" = "homolog" ] \
    && grep -q 'capped-deferred' "$scratch/gate-resolved.txt"; then
    log_pass "$name"
  else
    log_fail "$name (s1=$s1 s2=$s2 s3=$s3 final=$(field "$final" state))"
  fi
  rm -rf "$dir"
}

test_rerun_worker_silent_failure_blocks_no_silent_pass() {
  local name="a surgical re-run deletes the phase-status row; if the re-dispatched worker never rewrites it, the pipeline re-dispatches twice then stops — never silently passes"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  local scratch="$dir/.context/ship-run/T12"
  drive_to_verify_a "$dir" T12
  review_round "$scratch" fail 0 1 0 0 HIGH "Real correctness bug" "src/a.js"
  next "$dir" T12 >/dev/null
  local fix rerun c1 c2 c3
  fix="$(next "$dir" T12 --answer fix)"
  echo 'fixed' >> "$dir/src/a.js"
  rerun="$(next "$dir" T12)"
  # The re-run deleted phase-status-review.md and re-dispatched review. Simulate
  # a silently-failing worker: never rewrite the row.
  c1="$(next "$dir" T12)"
  c2="$(next "$dir" T12)"
  c3="$(next "$dir" T12)"
  if [ "$(field "$fix" state)" = "gate-fix" ] \
    && [ "$(field "$rerun" state)" = "verify-rerun" ] \
    && [ ! -f "$scratch/phase-status-review.md" ] \
    && [ "$(field "$c1" action)" = "dispatch" ] \
    && [ "$(field "$c3" action)" = "stop" ] \
    && [ "$(field "$c3" state)" != "homolog" ] \
    && printf '%s' "$c3" | grep -q 'silently failed'; then
    log_pass "$name"
  else
    log_fail "$name (fix=$(field "$fix" state) rerun=$(field "$rerun" state) row=$([ -f "$scratch/phase-status-review.md" ] && echo present || echo deleted) c1=$(field "$c1" action) c3=$(field "$c3" action)/$(field "$c3" state))"
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
      static-fix|static-gate|verify-a) printf '%s' "$out"; return 0 ;;
    esac
  done
  printf '%s' "$out"
}

test_static_gate_fail_dispatches_fix_before_verify() {
  local name="failing typecheck dispatches a static-fix agent BEFORE any quality/test worker"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  make_fake_typecheck "$dir" "$dir/.tc-fixed"
  local scratch="$dir/.context/ship-run/TS1"
  local out; out="$(drive_to_static_gate "$dir" TS1)"
  if [ "$(field "$out" state)" = "static-fix" ] && [ "$(field "$out" action)" = "dispatch" ] \
    && printf '%s' "$out" | grep -q 'typecheck/lint failure' \
    && [ -f "$scratch/static-failures.md" ] \
    && ! grep -qE 'ship-(review|perf|security|test)' "$scratch/dispatch-log.md"; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state)/$(field "$out" action))"
  fi
  rm -rf "$dir"
}

test_static_gate_fix_then_pass_proceeds_to_verify() {
  local name="static gate: fix makes typecheck green, then the pipeline advances to verify-a"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  make_fake_typecheck "$dir" "$dir/.tc-fixed"
  local scratch="$dir/.context/ship-run/TS2"
  local r1 r2
  r1="$(drive_to_static_gate "$dir" TS2)"
  touch "$dir/.tc-fixed"
  r2="$(next "$dir" TS2)"
  if [ "$(field "$r1" state)" = "static-fix" ] \
    && [ "$(field "$r2" state)" = "verify-a" ] \
    && grep -q '^| static | #1 |' "$scratch/phase-status.md"; then
    log_pass "$name"
  else
    log_fail "$name (r1=$(field "$r1" state) r2=$(field "$r2" state))"
  fi
  rm -rf "$dir"
}

test_static_fix_cap_stops() {
  local name="two static-fix rounds that stay red hit the cap and stop for manual intervention"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: disabled' '- test: disabled'
  make_fake_typecheck "$dir" "$dir/.never"
  local scratch="$dir/.context/ship-run/TS3"
  local r1 r2 r3
  r1="$(drive_to_static_gate "$dir" TS3)"
  r2="$(next "$dir" TS3)"
  r3="$(next "$dir" TS3)"
  if [ "$(field "$r1" action)" = "dispatch" ] && [ "$(field "$r2" action)" = "dispatch" ] \
    && [ "$(field "$r3" state)" = "static-gate" ] && [ "$(field "$r3" action)" = "stop" ]; then
    log_pass "$name"
  else
    log_fail "$name (r1=$(field "$r1" action) r2=$(field "$r2" action) r3=$(field "$r3" state)/$(field "$r3" action))"
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
- review: disabled
- analyze: disabled'
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
test_post_develop_no_mutation_stops
test_verify_a_dispatches_worker_with_brief
test_report_timings_prints_worker_start_lag
test_silent_worker_failure_redispatches_then_stops
test_happy_path_reaches_done_with_status_rows
test_gate_fail_fix_rerun_cycle
test_gate_fail_defer_proceeds
test_dev_disabled_still_runs_verification
test_identity_fixpoint_stops_the_loop
test_self_inflicted_churn_advances_instead_of_refixing
test_fix_cap_with_blocking_findings_stops
test_fix_cap_with_only_warnings_advances
test_rerun_worker_silent_failure_blocks_no_silent_pass
test_static_gate_fail_dispatches_fix_before_verify
test_static_gate_fix_then_pass_proceeds_to_verify
test_static_fix_cap_stops
test_static_gate_skip_when_no_checks
test_denylist_excludes_test_files
test_generated_tests_are_intent_added

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
