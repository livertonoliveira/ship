#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_SKILL="${REPO_ROOT}/src/skills/run/SKILL.md"
COMPILED_SKILL="${REPO_ROOT}/plugins/ship/skills/run/SKILL.md"
PHASE_HEADING='### 2. PHASE: Development'

VIOLATIONS=0

echo "Checking ship:run plan-validate wiring invariant..."
echo ""

check_file() {
  local file="$1"
  local invocation="$2"

  if [[ ! -f "$file" ]]; then
    echo "VIOLATION: ${file} not found"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
    return
  fi

  local invocation_line
  invocation_line=$(grep -nF "$invocation" "$file" | head -1 | cut -d: -f1 || true)

  local phase_line
  phase_line=$(grep -nF "$PHASE_HEADING" "$file" | head -1 | cut -d: -f1 || true)

  if [[ -z "$invocation_line" ]]; then
    echo "VIOLATION: ${file} does not invoke ${invocation}"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  if [[ -z "$phase_line" ]]; then
    echo "VIOLATION: ${file} is missing the '${PHASE_HEADING}' heading, position cannot be determined"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  if [[ -n "$invocation_line" && -n "$phase_line" && "$invocation_line" -ge "$phase_line" ]]; then
    echo "VIOLATION: ${file} invokes ${invocation} at line ${invocation_line}, which is not before the '${PHASE_HEADING}' heading at line ${phase_line}"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

check_file "$SRC_SKILL" 'bash "@@ship/hooks/plan-validate.sh"'
check_file "$COMPILED_SKILL" 'bash "${CLAUDE_SKILL_DIR}/hooks/plan-validate.sh"'

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — ship:run plan-validate wiring invariant holds (invocation present and precedes Development phase in both files)."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} violation(s) found in ship:run plan-validate wiring invariant."
  echo ""
  echo "Both src/skills/run/SKILL.md and plugins/ship/skills/run/SKILL.md must invoke"
  echo "plan-validate.sh before the '${PHASE_HEADING}' heading. Wire the gate into"
  echo "the planning phase and rebuild via 'cd plugins/ship && npm run build'."
  exit 1
fi
