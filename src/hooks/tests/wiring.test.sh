#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN_SKILL="$REPO_ROOT/src/skills/run/SKILL.md"
PIPELINE_SH="$REPO_ROOT/src/hooks/pipeline.sh"

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

test_run_skill_drives_pipeline_next() {
  local name="run SKILL.md drives the pipeline exclusively via pipeline.sh next"
  if grep -q '@@ship/hooks/pipeline.sh" next' "$RUN_SKILL"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_run_skill_next_removal_breaks_detection() {
  local name="removing the pipeline.sh next call from a scratch copy breaks the driver assertion"
  local stripped
  stripped="$(grep -v '@@ship/hooks/pipeline.sh" next' "$RUN_SKILL")"
  if printf '%s' "$stripped" | grep -q '@@ship/hooks/pipeline.sh" next'; then
    log_fail "$name (stripped copy still matched)"
  else
    log_pass "$name"
  fi
}

test_run_skill_has_no_phase_choreography() {
  local name="run SKILL.md contains no direct phase-hook choreography (all sequencing lives in pipeline.sh)"
  local leftovers
  leftovers="$(grep -nE '@@ship/hooks/(quality-scope|test-exec|plan-validate|rerun-scope|status-consolidate|evidence-gate|snapshot-files|analyze-precheck)\.sh' "$RUN_SKILL" || true)"
  if [ -z "$leftovers" ]; then
    log_pass "$name"
  else
    log_fail "$name (found: $leftovers)"
  fi
}

test_pipeline_next_wires_phase_hooks() {
  local name_prefix="pipeline.sh next wires"
  local script
  for script in plan-validate.sh quality-scope.sh test-scope.sh test-exec.sh \
    analyze-precheck.sh rerun-scope.sh status-consolidate.sh evidence-gate.sh \
    snapshot-files.sh findings-gate.sh plan-scope.sh; do
    if grep -q "\"\$HOOK_DIR/$script\"" "$PIPELINE_SH"; then
      log_pass "$name_prefix $script"
    else
      log_fail "$name_prefix $script (no \"\$HOOK_DIR/$script\" call site)"
    fi
  done
}

test_pipeline_next_state_machine_present() {
  local name="pipeline.sh exposes the next subcommand and its emission protocol"
  if grep -q 'cmd_next' "$PIPELINE_SH" \
    && grep -q "next)" "$PIPELINE_SH" \
    && grep -qE "printf 'state=%s" "$PIPELINE_SH"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_old_manual_run_substitution_prose_removed() {
  local name="the old manual RUN placeholder substitution prose no longer appears"
  if grep -qiE 'substitut(e|ing|ed|ua|uindo)[^.]*(#<RUN>|placeholder)' "$RUN_SKILL"; then
    log_fail "$name (found leftover manual-substitution prose)"
  else
    log_pass "$name"
  fi
}

test_old_manual_intersection_prose_removed() {
  local name="the old manual file-intersection prose no longer appears"
  if grep -qiE 'comput(e|ing|ando|ar) (a|the) intersecti?on of \(?modified files\)? and \(?phase scope\)?' "$RUN_SKILL"; then
    log_fail "$name (found leftover manual-intersection prose)"
  else
    log_pass "$name"
  fi
}

test_pipeline_init_self_contained() {
  local name="pipeline.sh's init subcommand is self-contained (no exec/dependency on a sibling run-init.sh)"
  if grep -q 'run-init.sh' "$PIPELINE_SH"; then
    log_fail "$name (pipeline.sh still references run-init.sh)"
    return
  fi

  if grep -q 'cmd_init' "$PIPELINE_SH"; then
    log_pass "$name"
  else
    log_fail "$name (no cmd_init function found)"
  fi
}

test_build_no_drift() {
  local name="rebuilding the plugin from src/ produces no drift under plugins/ship"
  (cd "$REPO_ROOT/plugins/ship" && npm run build >/dev/null 2>&1)

  if git -C "$REPO_ROOT" diff --exit-code -- plugins/ship >/dev/null 2>&1; then
    log_pass "$name"
  else
    log_fail "$name (git diff found drift under plugins/ship after rebuild)"
  fi
}

test_run_skill_drives_pipeline_next
test_run_skill_next_removal_breaks_detection
test_run_skill_has_no_phase_choreography
test_pipeline_next_wires_phase_hooks
test_pipeline_next_state_machine_present
test_old_manual_run_substitution_prose_removed
test_old_manual_intersection_prose_removed
test_pipeline_init_self_contained
test_build_no_drift

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
