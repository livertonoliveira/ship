#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_SKILL="${REPO_ROOT}/src/skills/run/SKILL.md"
COMPILED_SKILL="${REPO_ROOT}/plugins/ship/skills/run/SKILL.md"

SCRIPTS=("status-consolidate.sh" "evidence-gate.sh" "rerun-scope.sh")

VIOLATIONS=0

echo "Checking ship:run status scripts wiring invariant..."
echo ""

check_file() {
  local file="$1"
  local script="$2"

  if [[ ! -f "$file" ]]; then
    echo "VIOLATION: ${file} not found"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
    return
  fi

  if ! grep -qF "$script" "$file"; then
    echo "VIOLATION: ${file} does not invoke ${script}"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

check_hook_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "VIOLATION: ${file} not found"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

for script in "${SCRIPTS[@]}"; do
  check_file "$SRC_SKILL" "$script"
  check_file "$COMPILED_SKILL" "$script"
done

for script in "${SCRIPTS[@]}"; do
  check_hook_file "${REPO_ROOT}/src/hooks/${script}"
done

if [[ -d "${REPO_ROOT}/plugins/ship/hooks" ]]; then
  for script in "${SCRIPTS[@]}"; do
    check_hook_file "${REPO_ROOT}/plugins/ship/hooks/${script}"
  done
fi

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — ship:run status scripts wiring invariant holds (status-consolidate.sh, evidence-gate.sh and rerun-scope.sh are invoked in both SKILL.md files and exist under hooks/)."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} violation(s) found in ship:run status scripts wiring invariant."
  echo ""
  echo "Both src/skills/run/SKILL.md and plugins/ship/skills/run/SKILL.md must invoke"
  echo "status-consolidate.sh, evidence-gate.sh and rerun-scope.sh, and the three scripts"
  echo "must exist under hooks/. Wire the missing invocation or restore the missing file"
  echo "and rebuild via 'cd plugins/ship && npm run build'."
  exit 1
fi
