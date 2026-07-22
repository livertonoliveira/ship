#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_SKILL="${REPO_ROOT}/src/skills/run/SKILL.md"
COMPILED_SKILL="${REPO_ROOT}/plugins/ship/skills/run/SKILL.md"
SRC_PIPELINE="${REPO_ROOT}/src/hooks/pipeline.sh"
COMPILED_PIPELINE="${REPO_ROOT}/plugins/ship/hooks/pipeline.sh"

VIOLATIONS=0

echo "Checking ship:run plan-validate wiring invariant..."
echo ""

# plan-validate.sh counts as wired when the run SKILL invokes it directly, or
# transitively: the SKILL drives pipeline.sh (the `next` state machine) and
# pipeline.sh invokes plan-validate.sh. This mirrors the transitive rule the
# status-scripts guard adopted when post-develop collapsed into pipeline.sh.
check_skill_wiring() {
  local skill="$1" pipeline="$2"

  if [[ ! -f "$skill" ]]; then
    echo "VIOLATION: ${skill} not found"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
    return
  fi

  if grep -qF "plan-validate.sh" "$skill"; then
    return
  fi

  if grep -qF "pipeline.sh" "$skill" && [[ -f "$pipeline" ]] && grep -qF "plan-validate.sh" "$pipeline"; then
    return
  fi

  echo "VIOLATION: ${skill} does not invoke plan-validate.sh (directly or via pipeline.sh)"
  echo ""
  VIOLATIONS=$((VIOLATIONS + 1))
}

# Ordering invariant: inside pipeline.sh's state machine, plan validation must
# run before the develop dispatch — an unvalidated plan must never reach the
# implementer.
check_pipeline_ordering() {
  local pipeline="$1"

  if [[ ! -f "$pipeline" ]]; then
    echo "VIOLATION: ${pipeline} not found"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
    return
  fi

  local validate_line develop_line
  validate_line=$(grep -nF 'plan-validate.sh' "$pipeline" | head -1 | cut -d: -f1 || true)
  develop_line=$(grep -nF 'Skill ship:develop' "$pipeline" | head -1 | cut -d: -f1 || true)

  if [[ -z "$validate_line" ]]; then
    echo "VIOLATION: ${pipeline} does not invoke plan-validate.sh"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
    return
  fi

  if [[ -z "$develop_line" ]]; then
    echo "VIOLATION: ${pipeline} does not dispatch ship:develop, ordering cannot be determined"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
    return
  fi

  if [[ "$validate_line" -ge "$develop_line" ]]; then
    echo "VIOLATION: ${pipeline} invokes plan-validate.sh at line ${validate_line}, which is not before the ship:develop dispatch at line ${develop_line}"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

check_skill_wiring "$SRC_SKILL" "$SRC_PIPELINE"
check_skill_wiring "$COMPILED_SKILL" "$COMPILED_PIPELINE"
check_pipeline_ordering "$SRC_PIPELINE"
check_pipeline_ordering "$COMPILED_PIPELINE"

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — ship:run plan-validate wiring invariant holds (wired directly or via pipeline.sh, and validation precedes the develop dispatch in the state machine)."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} violation(s) found in ship:run plan-validate wiring invariant."
  echo ""
  echo "Both run SKILL.md files must reach plan-validate.sh — directly or via"
  echo "pipeline.sh — and pipeline.sh's state machine must validate the plan before"
  echo "dispatching ship:develop. Wire the gate and rebuild via"
  echo "'cd plugins/ship && npm run build'."
  exit 1
fi
