#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN_SKILL="$REPO_ROOT/src/skills/run/SKILL.md"

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

test_status_consolidate_wired_in_two_sites() {
  local name="run SKILL.md invokes status-consolidate.sh in the two remaining designated sites"
  local count
  count="$(grep -c '@@ship/hooks/status-consolidate.sh' "$RUN_SKILL" || true)"

  if [ "$count" -eq 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (found $count occurrence(s), expected 2)"
  fi
}

test_pipeline_complete_wired_in_develop_consolidation_site() {
  local name="run SKILL.md invokes pipeline.sh complete in the develop-consolidation site"
  if grep -q '@@ship/hooks/pipeline.sh" complete' "$RUN_SKILL"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_status_consolidate_near_develop_consolidation() {
  local name="the develop-phase consolidation section references pipeline.sh complete"
  if grep -A5 'Consolidate phase-status (MANDATORY, before proceeding)' "$RUN_SKILL" | grep -q '@@ship/hooks/pipeline.sh" complete'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_status_consolidate_near_gate_check() {
  local name="the gate-check consolidation section references status-consolidate.sh"
  if grep -A5 'Consolidate phase-status (MANDATORY, before evaluating the gate)' "$RUN_SKILL" | grep -q '@@ship/hooks/status-consolidate.sh'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_status_consolidate_near_surgical_rerun() {
  local name="the surgical re-run step references status-consolidate.sh"
  if grep -B2 -A2 'add `notes=re-run cirúrgico`' "$RUN_SKILL" | grep -q '@@ship/hooks/status-consolidate.sh'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_run_context_init_wired_in_init_section() {
  local name="the run-context init section invokes pipeline.sh init"
  local section
  section="$(sed -n '/### 0.4–0.7\. Initialize the run context/,/### 1\. Load task context/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q '@@ship/hooks/pipeline.sh" init'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_run_context_init_call_removal_breaks_detection() {
  local name="removing the pipeline.sh init call from a scratch copy breaks the init-section assertion"
  local section stripped
  section="$(sed -n '/### 0.4–0.7\. Initialize the run context/,/### 1\. Load task context/p' "$RUN_SKILL")"
  stripped="$(printf '%s' "$section" | grep -v '@@ship/hooks/pipeline.sh" init')"

  if printf '%s' "$stripped" | grep -q '@@ship/hooks/pipeline.sh" init'; then
    log_fail "$name (stripped copy still matched)"
  else
    log_pass "$name"
  fi
}

test_phase2_development_wired_in_pipeline_dispatch() {
  local name="the Phase 2 development section invokes pipeline.sh dispatch for the dev phase"
  local section
  section="$(sed -n '/### 2\. PHASE: Development/,/### 2.5\. Refresh diff/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q 'pipeline.sh dispatch' && printf '%s' "$section" | grep -q '`dev`'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_phase2_development_pipeline_dispatch_removal_breaks_detection() {
  local name="removing the pipeline.sh dispatch reference from a scratch copy breaks the Phase 2 assertion"
  local section stripped
  section="$(sed -n '/### 2\. PHASE: Development/,/### 2.5\. Refresh diff/p' "$RUN_SKILL")"
  stripped="$(printf '%s' "$section" | grep -v 'pipeline.sh dispatch')"

  if printf '%s' "$stripped" | grep -q 'pipeline.sh dispatch'; then
    log_fail "$name (stripped copy still matched)"
  else
    log_pass "$name"
  fi
}

test_pipeline_complete_call_removal_breaks_detection() {
  local name="removing the pipeline.sh complete call from a scratch copy breaks the develop-consolidation assertion"
  local section stripped
  section="$(grep -A5 'Consolidate phase-status (MANDATORY, before proceeding)' "$RUN_SKILL")"
  stripped="$(printf '%s' "$section" | grep -v '@@ship/hooks/pipeline.sh" complete')"

  if printf '%s' "$stripped" | grep -q '@@ship/hooks/pipeline.sh" complete'; then
    log_fail "$name (stripped copy still matched)"
  else
    log_pass "$name"
  fi
}

test_pipeline_gate_wired_in_gate_check_section() {
  local name="the GATE CHECK section invokes pipeline.sh gate"
  local section
  section="$(sed -n '/### 5\. GATE CHECK/,/#### Surgical Re-run Procedure/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q '@@ship/hooks/pipeline.sh" gate'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_pipeline_gate_call_removal_breaks_detection() {
  local name="removing the pipeline.sh gate call from a scratch copy breaks the GATE CHECK assertion"
  local section stripped
  section="$(sed -n '/### 5\. GATE CHECK/,/#### Surgical Re-run Procedure/p' "$RUN_SKILL")"
  stripped="$(printf '%s' "$section" | grep -v '@@ship/hooks/pipeline.sh" gate')"

  if printf '%s' "$stripped" | grep -q '@@ship/hooks/pipeline.sh" gate'; then
    log_fail "$name (stripped copy still matched)"
  else
    log_pass "$name"
  fi
}

test_evidence_gate_wired_in_develop_section() {
  local name="the develop evidence gate section invokes evidence-gate.sh"
  local section
  section="$(sed -n '/### 2.6. Develop evidence gate/,/### 3. PHASE: Testing/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q '@@ship/hooks/evidence-gate.sh'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_rerun_scope_wired_in_surgical_rerun_step() {
  local name="the surgical re-run procedure invokes rerun-scope.sh"
  local section
  section="$(sed -n '/#### Surgical Re-run Procedure/,/### 6. PHASE: User Acceptance/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q '@@ship/hooks/rerun-scope.sh'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_pipeline_iter_wired_in_surgical_rerun_step() {
  local name="the surgical re-run procedure invokes pipeline.sh iter with the fix counter, max 3"
  local section
  section="$(sed -n '/#### Surgical Re-run Procedure/,/### 6. PHASE: User Acceptance/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q '@@ship/hooks/pipeline.sh" iter .context/ship-run/<task-id> fix --max 3'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_pipeline_iter_wired_in_test_exec_step() {
  local name="the test-execution step invokes pipeline.sh iter with the test-fix counter, max 2"
  local section
  section="$(sed -n '/\*\*(a) Test execution:\*\*/,/Reconciliation/p' "$RUN_SKILL")"

  if printf '%s' "$section" | grep -q '@@ship/hooks/pipeline.sh" iter .context/ship-run/<task-id> test-fix --max 2'; then
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
  local pipeline_sh="$REPO_ROOT/src/hooks/pipeline.sh"

  if grep -q 'run-init.sh' "$pipeline_sh"; then
    log_fail "$name (pipeline.sh still references run-init.sh)"
    return
  fi

  if grep -q 'cmd_init' "$pipeline_sh"; then
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

test_status_consolidate_wired_in_two_sites
test_pipeline_complete_wired_in_develop_consolidation_site
test_status_consolidate_near_develop_consolidation
test_status_consolidate_near_gate_check
test_status_consolidate_near_surgical_rerun
test_run_context_init_wired_in_init_section
test_run_context_init_call_removal_breaks_detection
test_phase2_development_wired_in_pipeline_dispatch
test_phase2_development_pipeline_dispatch_removal_breaks_detection
test_pipeline_complete_call_removal_breaks_detection
test_pipeline_gate_wired_in_gate_check_section
test_pipeline_gate_call_removal_breaks_detection
test_evidence_gate_wired_in_develop_section
test_rerun_scope_wired_in_surgical_rerun_step
test_pipeline_iter_wired_in_surgical_rerun_step
test_pipeline_iter_wired_in_test_exec_step
test_old_manual_run_substitution_prose_removed
test_old_manual_intersection_prose_removed
test_pipeline_init_self_contained
test_build_no_drift

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
