#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_SKILL="${REPO_ROOT}/src/skills/run/SKILL.md"
COMPILED_SKILL="${REPO_ROOT}/plugins/ship/skills/run/SKILL.md"
MAX_LINES=780

VIOLATIONS=0

echo "Checking ship:run lazy-load invariant..."
echo ""

if [[ -f "$SRC_SKILL" ]]; then
  inline_matches=$(grep -nE '(^|[^@])@ship/patterns/' "$SRC_SKILL" || true)
  if [[ -n "$inline_matches" ]]; then
    echo "VIOLATION: inline @ship/patterns/ ref found in ${SRC_SKILL}"
    echo "$inline_matches" | sed 's/^/  /'
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
else
  echo "VIOLATION: ${SRC_SKILL} not found"
  echo ""
  VIOLATIONS=$((VIOLATIONS + 1))
fi

if [[ -f "$COMPILED_SKILL" ]]; then
  line_count=$(wc -l < "$COMPILED_SKILL" | tr -d '[:space:]')
  if [[ "$line_count" -gt "$MAX_LINES" ]]; then
    echo "VIOLATION: ${COMPILED_SKILL} has ${line_count} lines, exceeding budget of ${MAX_LINES}"
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
else
  echo "VIOLATION: ${COMPILED_SKILL} not found"
  echo ""
  VIOLATIONS=$((VIOLATIONS + 1))
fi

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — ship:run lazy-load invariant holds (no inline patterns refs, compiled SKILL within budget)."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} violation(s) found in ship:run lazy-load invariant."
  echo ""
  echo "src/skills/run/SKILL.md must reference patterns via lazy @@ship/patterns/ refs,"
  echo "not inline @ship/patterns/ refs, and the compiled plugins/ship/skills/run/SKILL.md"
  echo "must stay within its line budget (MAX_LINES=${MAX_LINES}). Revert any reintroduced"
  echo "inline pattern content and rebuild via 'cd plugins/ship && npm run build'."
  exit 1
fi
