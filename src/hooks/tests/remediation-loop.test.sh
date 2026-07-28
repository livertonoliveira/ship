#!/usr/bin/env bash

# Composition test for the remediation path: drives the REAL `pipeline.sh next`
# loop turn by turn with scripted stand-ins for the agents it dispatches.
#
# The unit tests cover each piece (batch assembly, verdict scoring, the gate's
# hard-fail rule) and the E2E smoke covers the all-green pipeline. Neither covers
# what happens across the turns of an actual remediation round, because the E2E
# fixture runs with on_fail: defer so its gate never enters this path. What is
# untested is the composition: static red surviving to the gate, one batch, one
# fix dispatch, the confirmation rewriting the phase rows, and the gate then
# re-deciding from those rewritten rows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

field() { printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-; }

SCEN_ID="@S"'C-01'

setup_repo() {
  local dir="$1"
  mkdir -p "$dir/ship"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    # A typecheck that stays red until the fix agent drops the sentinel — the
    # deterministic half of a batch, with a verdict the script can re-derive.
    printf '#!/usr/bin/env bash\n[ -f "%s/.tc-fixed" ] && exit 0\necho "src/a.js(1,1): error TS2304: Cannot find name x"\nexit 2\n' "$dir" > tc.sh
    chmod +x tc.sh
    {
      printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n'
      printf '\n## Pipeline Profile\n- profile: standard\n'
      printf '\n## Test Scope\n- unit: disabled\n- integration: disabled\n- e2e: disabled\n'
      printf '\n## Pipeline Phases\n- test: disabled\n- homolog: disabled\n'
      printf '\n## Gate Behavior\n- on_fail: fix\n- on_warn: fix\n'
      printf '\n- Test Framework: none\n- Typecheck: %s/tc.sh\n' "$dir"
    } > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null
}

next() {
  local dir="$1"; shift
  (cd "$dir" && bash "$PIPELINE" next "$@")
}

spec_fixture() {
  cat <<EOF
## Files
- create \`src/a.js\` — the module

Dependencies: None

$SCEN_ID @unit
Scenario: works
  Given a value
  Then it works
EOF
}

plan_fixture() {
  cat <<EOF
## Modules
### M1: core
- Files: src/a.js
- Depends on: none
- Scenarios: $SCEN_ID
- Contract: does things

## Test Contract
### $SCEN_ID -> unit -> src/a.test.js
- arrange/act/assert: x
EOF
}

# --- scripted agents ---------------------------------------------------------

# Over 100 changed lines on purpose: diff-classify calls anything under that in a
# single file `minor`, and quality-scope then skips review — which would leave the
# fixture silently exercising only the deterministic half of the batch.
mock_develop() {
  local dir="$1"
  mkdir -p "$dir/src"
  seq 1 120 | sed 's/^/export const v/;s/$/ = 1/' > "$dir/src/a.js"
}

# Writes the row (and findings file) for each quality phase the instruction
# actually dispatched, so the mock tracks the real scope decision rather than
# assuming one.
mock_quality_workers() {
  local dir="$1" scratch="$2" out="$3" ph
  for ph in perf security review; do
    printf '%s' "$out" | grep -q "subagent_type=ship:ship-$ph" || continue
    if [ "$ph" = "review" ] && [ "${SEED_FINDING:-1}" = "1" ]; then
      printf '| review | #<RUN> | 2026-01-01T00:00:00Z | - | fail | 0 | 1 | 0 | 0 | |\n' \
        > "$scratch/phase-status-review.md"
      printf '### [HIGH] Race condition on idempotency\n- **File:** src/a.js:2\n' \
        > "$scratch/review-findings.md"
    else
      printf '| %s | #<RUN> | 2026-01-01T00:00:00Z | - | pass | 0 | 0 | 0 | 0 | |\n' "$ph" \
        > "$scratch/phase-status-$ph.md"
    fi
  done
}

# The fix agent: reads the batch and addresses every item. FIX_MODE controls how
# faithfully, so a fix that does nothing can be tested too.
mock_fix_agent() {
  local dir="$1" scratch="$2"
  FIX_DISPATCHES=$((FIX_DISPATCHES + 1))
  BATCH_ITEMS="$(grep -c '^### R' "$scratch/remediation.md" 2>/dev/null || echo 0)"
  case "${FIX_MODE:-full}" in
    full)
      touch "$dir/.tc-fixed"
      printf 'export const fixed = 1\n' >> "$dir/src/a.js"
      ;;
    noop) ;;
  esac
}

mock_confirm_agent() {
  local scratch="$1" id
  CONFIRM_DISPATCHES=$((CONFIRM_DISPATCHES + 1))
  : > "$scratch/remediation-verify.md"
  while IFS='|' read -r id kind _ _ _ _; do
    [ "$kind" = "finding" ] || continue
    printf -- '- %s: %s\n' "$id" "${CONFIRM_VERDICT:-resolved}" >> "$scratch/remediation-verify.md"
  done < "$scratch/remediation-items.txt"
}

# --- driver ------------------------------------------------------------------

# Runs the loop until a terminal action, playing whichever agent the state
# machine asks for. Records the state sequence so a test can assert on shape.
drive() {
  local dir="$1" task="$2" max="${3:-20}"
  local scratch="$dir/.context/ship-run/$task"
  local i out state action
  STATES=""
  FIX_DISPATCHES=0
  CONFIRM_DISPATCHES=0
  for i in $(seq 1 "$max"); do
    out="$(next "$dir" "$task" 2>&1)" || { LAST_OUT="$out"; return 1; }
    state="$(field "$out" state)"
    action="$(field "$out" action)"
    STATES="$STATES $state"
    LAST_OUT="$out"
    LAST_STATE="$state"
    LAST_ACTION="$action"
    case "$action" in
      ask|stop|done) return 0 ;;
    esac
    case "$state" in
      context)            spec_fixture > "$scratch/spec.md" ;;
      plan)               plan_fixture > "$scratch/plan.md" ;;
      plan-review)        printf 'verdict: ok\n' > "$scratch/plan-review.md" ;;
      develop)            mock_develop "$dir" ;;
      verify-a|verify-pending) mock_quality_workers "$dir" "$scratch" "$out" ;;
      remediation-fix)    mock_fix_agent "$dir" "$scratch" ;;
      remediation-verify) mock_confirm_agent "$scratch" ;;
      homolog)            return 0 ;;
    esac
  done
  return 1
}

count_state() { printf '%s' "$STATES" | tr ' ' '\n' | grep -cx "$1" || true; }

# --- tests -------------------------------------------------------------------

test_remediation_rounds_are_recorded_in_the_dispatch_log() {
  local name="the remediation round appears in dispatch-log.md so it reaches the timings and the user's trace"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  local scratch="$dir/.context/ship-run/T7"
  SEED_FINDING=1 FIX_MODE=full CONFIRM_VERDICT=resolved
  drive "$dir" T7 || true
  local fixn confn
  fixn="$(grep -c '| remediation-fix |' "$scratch/dispatch-log.md" 2>/dev/null)" || fixn=0
  confn="$(grep -c '| remediation-verify |' "$scratch/dispatch-log.md" 2>/dev/null)" || confn=0
  if [ "$fixn" = "1" ] && [ "$confn" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (fix rows=$fixn confirm rows=$confn)"
  fi
  rm -rf "$dir"
}

test_one_batch_one_fix_one_confirmation() {
  local name="a red typecheck and a finding resolve in exactly one fix and one confirmation"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  local scratch="$dir/.context/ship-run/T1"
  SEED_FINDING=1 FIX_MODE=full CONFIRM_VERDICT=resolved
  drive "$dir" T1 || true
  if [ "$FIX_DISPATCHES" = "1" ] && [ "$CONFIRM_DISPATCHES" = "1" ] \
    && [ "$BATCH_ITEMS" = "2" ] \
    && [ "$LAST_STATE" = "done" ] \
    && [ "$(head -1 "$scratch/gate-resolved.txt")" = "PASS" ]; then
    log_pass "$name"
  else
    log_fail "$name (fix=$FIX_DISPATCHES confirm=$CONFIRM_DISPATCHES items=$BATCH_ITEMS last=$LAST_STATE/$LAST_ACTION gate=$(cat "$scratch/gate-resolved.txt" 2>/dev/null))"
  fi
  rm -rf "$dir"
}

test_static_failure_reaches_the_gate_not_its_own_loop() {
  local name="the red typecheck reaches the consolidated gate instead of halting before the fan-out"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  local scratch="$dir/.context/ship-run/T2"
  SEED_FINDING=1 FIX_MODE=full CONFIRM_VERDICT=resolved
  drive "$dir" T2 || true
  # The batch held both detectors at once — the whole point of the change.
  if grep -q 'typecheck/lint' "$scratch/remediation.md" \
    && grep -q 'race-condition-on-idempotency' "$scratch/remediation.md" \
    && [ "$(count_state verify-a)" = "1" ] \
    && ! grep -q 'static-fix' "$scratch/dispatch-log.md" 2>/dev/null; then
    log_pass "$name"
  else
    log_fail "$name (states:$STATES)"
  fi
  rm -rf "$dir"
}

test_confirmation_rewrites_rows_and_the_gate_re_decides() {
  local name="the confirmation's verdicts rewrite the phase row the gate then re-reads"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  local scratch="$dir/.context/ship-run/T3"
  SEED_FINDING=1 FIX_MODE=full CONFIRM_VERDICT=resolved
  drive "$dir" T3 || true
  # review entered at fail/high=1 and must leave at pass/0 without any worker
  # having been re-dispatched.
  if grep -qE '^\| review \|.*\| pass \| 0 \| 0 \| 0 \| 0 \|' "$scratch/phase-status-review.md" \
    && grep -q 'após remediação' "$scratch/phase-status-review.md" \
    && [ "$(grep -c 'ship-review' "$scratch/dispatch-log.md")" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (row=$(cat "$scratch/phase-status-review.md" 2>/dev/null))"
  fi
  rm -rf "$dir"
}

test_residue_asks_instead_of_looping() {
  local name="an unresolved item stops for the user instead of starting a second automatic round"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  local scratch="$dir/.context/ship-run/T4"
  SEED_FINDING=1 FIX_MODE=full CONFIRM_VERDICT=unresolved
  drive "$dir" T4 || true
  if [ "$FIX_DISPATCHES" = "1" ] && [ "$LAST_STATE" = "gate" ] && [ "$LAST_ACTION" = "ask" ] \
    && printf '%s' "$LAST_OUT" | grep -q 'R2'; then
    log_pass "$name"
  else
    log_fail "$name (fix=$FIX_DISPATCHES last=$LAST_STATE/$LAST_ACTION)"
  fi
  rm -rf "$dir"
}

test_deterministic_only_batch_skips_the_confirmation_agent() {
  local name="a batch with no findings spends no turn on a confirmation agent"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  local scratch="$dir/.context/ship-run/T5"
  SEED_FINDING=0 FIX_MODE=full CONFIRM_VERDICT=resolved
  drive "$dir" T5 || true
  if [ "$FIX_DISPATCHES" = "1" ] && [ "$CONFIRM_DISPATCHES" = "0" ] \
    && [ "$BATCH_ITEMS" = "1" ] && [ "$LAST_STATE" = "done" ]; then
    log_pass "$name"
  else
    log_fail "$name (fix=$FIX_DISPATCHES confirm=$CONFIRM_DISPATCHES items=$BATCH_ITEMS last=$LAST_STATE)"
  fi
  rm -rf "$dir"
}

test_a_fix_that_changes_nothing_still_terminates() {
  local name="a fix agent that changes nothing does not loop — the round is spent and the user decides"
  local dir; dir="$(mktemp -d)"; setup_repo "$dir"
  SEED_FINDING=0 FIX_MODE=noop CONFIRM_VERDICT=resolved
  drive "$dir" T6 || true
  if [ "$FIX_DISPATCHES" = "1" ] \
    && { [ "$LAST_ACTION" = "ask" ] || [ "$LAST_ACTION" = "stop" ]; }; then
    log_pass "$name"
  else
    log_fail "$name (fix=$FIX_DISPATCHES last=$LAST_STATE/$LAST_ACTION states:$STATES)"
  fi
  rm -rf "$dir"
}

test_one_batch_one_fix_one_confirmation
test_static_failure_reaches_the_gate_not_its_own_loop
test_confirmation_rewrites_rows_and_the_gate_re_decides
test_residue_asks_instead_of_looping
test_deterministic_only_batch_skips_the_confirmation_agent
test_a_fix_that_changes_nothing_still_terminates
test_remediation_rounds_are_recorded_in_the_dispatch_log

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
