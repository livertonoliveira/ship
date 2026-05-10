#!/usr/bin/env bash
# check-no-audit-in-pipeline.sh
#
# Verifies that no pipeline skill file invokes audit:* commands.
# Audit commands are project-wide and must NOT be called from within ship:run
# or any pipeline phase (develop, test, perf, security, review, analyze, homolog, pr).
#
# The check targets actual invocations (Skill tool calls, /ship:audit: command
# references in imperative context) — not documentation mentions that merely
# reference audit commands as alternatives for the user to run separately.
#
# Usage: ./scripts/check-no-audit-in-pipeline.sh
# Exit code 0 = clean; exit code 1 = violation(s) found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pipeline skill directories — audit:* skills are intentionally excluded
PIPELINE_SKILLS=(
  "ship:run"
  "ship:develop"
  "ship:test"
  "ship:perf"
  "ship:security"
  "ship:review"
  "ship:analyze"
  "ship:homolog"
  "ship:pr"
  "ship:spec"
  "ship:init"
  "ship:update"
)

SKILLS_BASE="${REPO_ROOT}/plugins/ship/skills"
COMMANDS_BASE="${REPO_ROOT}/.claude/commands/ship"

VIOLATIONS=0

# Patterns that indicate an actual audit invocation (not documentation):
#   - Invoke `/ship:audit:...`
#   - skill: ship:audit:...
#   - /ship:audit:run  (used as a command, not just mentioned as "run X" for the user)
# We specifically exclude lines that are:
#   - Comments starting with # (config file examples)
#   - Lines with "run `" or "run /ship:audit" that suggest user action (but we catch imperative ones)
#   - Lines matching "do not audit ... run /ship:audit" (documentation advice)
INVOCATION_PATTERN='(Invoke|invoke|skill:[[:space:]]*ship:audit:|Skill tool.*audit:|audit:run.*Skill)'

check_file() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    return
  fi

  # Match lines with audit: that look like actual invocations, not documentation
  # Exclude lines that are:
  #   - pure documentation references ("run /ship:audit:X", "via /ship:audit:X")
  #   - config file comments (lines starting with optional whitespace then #)
  local matches
  matches=$(grep -n "audit:" "$file" 2>/dev/null \
    | grep -Ev '^\s*[0-9]+:[[:space:]]*(#|//|<!--)' \
    | grep -Ev 'do not audit.*run.*audit:' \
    | grep -Ev 'For project-wide.*run.*audit:' \
    | grep -Ev 'backfilled via.*audit:' \
    | grep -Ev 'run `.*audit:' \
    | grep -E "$INVOCATION_PATTERN" \
    || true)

  if [[ -n "$matches" ]]; then
    echo "VIOLATION: ${label}"
    echo "$matches" | sed 's/^/  /'
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

echo "Checking pipeline skill files for audit:* invocations..."
echo ""

for skill in "${PIPELINE_SKILLS[@]}"; do
  skill_file="${SKILLS_BASE}/${skill}/SKILL.md"
  check_file "$skill_file" "$skill_file"
done

echo "Checking legacy command files for audit:* invocations..."
echo ""

if [[ -d "$COMMANDS_BASE" ]]; then
  for skill in "${PIPELINE_SKILLS[@]}"; do
    cmd_file="${COMMANDS_BASE}/${skill#ship:}.md"
    check_file "$cmd_file" "$cmd_file"
  done
fi

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — no audit:* invocations found in pipeline skill files."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} file(s) contain audit:* invocations in the pipeline."
  echo ""
  echo "Audit commands (audit:backend, audit:frontend, audit:database, audit:security,"
  echo "audit:tests, audit:run) are project-wide and must NOT be invoked from within"
  echo "ship:run or any pipeline phase. Users run audits separately at planned moments"
  echo "(pre-release, periodic health checks)."
  exit 1
fi
