#!/usr/bin/env bash
# check-wrapper-is-thin.sh
#
# Lints worker Skill wrappers to ensure they stay thin and do not contain
# inline methodology. Each wrapper in src/skills/<worker>/SKILL.md is checked
# for two conditions:
#
# develop is intentionally excluded: it is a sequential inline implementer,
# not a wrapper dispatching to a named Agent (see WORKER_SKILLS below).
#
#  1. Content line count (excluding YAML frontmatter and fenced code blocks)
#     must not exceed 100 lines.
#  2. The file must reference a named-agent invocation via `subagent_type: ship-*`.
#
# Usage: ./scripts/check-wrapper-is-thin.sh
# Exit code 0 = clean; exit code 1 = violation(s) found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_BASE="${REPO_ROOT}/src/skills"

WORKER_SKILLS=(
  perf security review analyze test
  "audit:backend" "audit:frontend" "audit:database" "audit:security" "audit:tests"
)

LINE_LIMIT=100
VIOLATIONS=0

echo "Scanning worker wrappers for inline methodology..."
echo ""

check_file() {
  local file="$1"
  local worker="$2"
  local file_violations=0

  # Count content lines excluding YAML frontmatter and fenced code blocks.
  # Uses awk state machine:
  #   - skip leading frontmatter (first --- ... --- block)
  #   - skip fenced code blocks (``` ... ```)
  #   - count all other non-empty lines
  local content_lines
  content_lines=$(awk '
    BEGIN { in_frontmatter=0; frontmatter_done=0; in_fence=0; count=0 }
    NR==1 && /^---[[:space:]]*$/ { in_frontmatter=1; next }
    in_frontmatter && /^---[[:space:]]*$/ { in_frontmatter=0; frontmatter_done=1; next }
    in_frontmatter { next }
    /^```/ { in_fence = !in_fence; next }
    in_fence { next }
    { count++ }
    END { print count }
  ' "$file")

  # Check for a named-agent dispatch: subagent_type: ship-* or the
  # plugin-prefixed form subagent_type: ship:ship-* (the form skills actually use).
  local has_subagent
  has_subagent=$(grep -cE 'subagent_type:[[:space:]]*(ship:)?ship-' "$file" || true)

  if [[ "$content_lines" -gt "$LINE_LIMIT" ]]; then
    echo "VIOLATION: src/skills/${worker}/SKILL.md"
    echo "  Wrapper has ${content_lines} lines (limit: ${LINE_LIMIT}) — likely contains inline methodology"
    echo ""
    file_violations=$((file_violations + 1))
  fi

  if [[ "$has_subagent" -eq 0 ]]; then
    echo "VIOLATION: src/skills/${worker}/SKILL.md"
    echo "  Wrapper does not invoke a named Agent — missing \`subagent_type: ship-*\` reference"
    echo ""
    file_violations=$((file_violations + 1))
  fi

  return "$file_violations"
}

for worker in "${WORKER_SKILLS[@]}"; do
  file="${SKILLS_BASE}/${worker}/SKILL.md"

  if [[ ! -f "$file" ]]; then
    echo "WARNING: src/skills/${worker}/SKILL.md not found — skipping" >&2
    continue
  fi

  file_violations=0
  check_file "$file" "$worker" || file_violations=$?
  VIOLATIONS=$((VIOLATIONS + file_violations))
done

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "Found 0 violation(s)."
  exit 0
else
  echo "Found ${VIOLATIONS} violation(s)."
  exit 1
fi
