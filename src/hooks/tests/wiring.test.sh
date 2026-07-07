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

test_status_consolidate_wired_in_three_sites() {
  local name="run SKILL.md invokes status-consolidate.sh in all three designated sites"
  local count
  count="$(grep -c '@@ship/hooks/status-consolidate.sh' "$RUN_SKILL" || true)"

  if [ "$count" -eq 3 ]; then
    log_pass "$name"
  else
    log_fail "$name (found $count occurrence(s), expected 3)"
  fi
}

test_status_consolidate_near_develop_consolidation() {
  local name="the develop-phase consolidation section references status-consolidate.sh"
  if grep -A5 'Consolidate phase-status (MANDATORY, before proceeding)' "$RUN_SKILL" | grep -q '@@ship/hooks/status-consolidate.sh'; then
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

test_build_no_drift() {
  local name="rebuilding the plugin from src/ produces no drift under plugins/ship"
  (cd "$REPO_ROOT/plugins/ship" && npm run build >/dev/null 2>&1)

  if git -C "$REPO_ROOT" diff --exit-code -- plugins/ship >/dev/null 2>&1; then
    log_pass "$name"
  else
    log_fail "$name (git diff found drift under plugins/ship after rebuild)"
  fi
}

test_status_consolidate_wired_in_three_sites
test_status_consolidate_near_develop_consolidation
test_status_consolidate_near_gate_check
test_status_consolidate_near_surgical_rerun
test_evidence_gate_wired_in_develop_section
test_rerun_scope_wired_in_surgical_rerun_step
test_old_manual_run_substitution_prose_removed
test_old_manual_intersection_prose_removed
test_build_no_drift

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
