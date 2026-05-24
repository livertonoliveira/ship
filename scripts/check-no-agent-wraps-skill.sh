#!/usr/bin/env bash
# check-no-agent-wraps-skill.sh
#
# Detects the anti-pattern where a SKILL.md instructs the orchestrator to
# launch a sub-agent via the Agent tool and then have that sub-agent invoke
# another `ship:X` skill via the Skill tool.
#
# This pattern fails at runtime: sub-agents spawned via Agent do not inherit
# the parent's plugin skill registry, so the Skill call cannot resolve
# `ship:X` and the LLM falls back to hallucinating file paths (e.g.
# `.claude/commands/ship/X.md`, the pre-v2.0.0 layout).
#
# Correct pattern: the parent skill invokes `ship:X` directly via the Skill
# tool, and the target skill declares `context: fork` in its frontmatter so
# Claude Code forks an isolated subagent automatically. See
# https://code.claude.com/docs/en/skills#run-skills-in-a-subagent
#
# Heuristic: within any SKILL.md under src/skills/, look for an
# "Use the **Agent** tool" / "Use the Agent tool" line followed within the
# next 25 lines by an "Invoke the `ship:...` skill via ... Skill tool" line.
#
# Usage: ./scripts/check-no-agent-wraps-skill.sh
# Exit code 0 = clean; exit code 1 = violation(s) found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_BASE="${REPO_ROOT}/src/skills"

VIOLATIONS=0
WINDOW=25

check_file() {
  local file="$1"
  awk -v window="$WINDOW" -v file="$file" '
    /Use the \*\*Agent\*\* tool|Use the Agent tool/ {
      agent_line = NR
      agent_text = $0
    }
    /Invoke the `ship:[a-zA-Z:-]+`.*Skill tool/ {
      if (agent_line > 0 && (NR - agent_line) <= window) {
        printf "VIOLATION: %s\n", file
        printf "  L%d: %s\n", agent_line, agent_text
        printf "  L%d: %s\n\n", NR, $0
        found = 1
        agent_line = 0
      }
    }
    END { exit found ? 1 : 0 }
  ' "$file" || return 1
  return 0
}

echo "Scanning src/skills/**/SKILL.md for Agent→Skill(ship:X) anti-pattern..."
echo ""

while IFS= read -r -d '' file; do
  if ! check_file "$file"; then
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done < <(find "$SKILLS_BASE" -name "SKILL.md" -print0)

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — no Agent-wraps-Skill anti-pattern found."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} file(s) contain the anti-pattern."
  echo ""
  echo "The orchestrator must invoke phase skills via the Skill tool directly."
  echo "Each phase skill should declare 'context: fork' in its frontmatter so"
  echo "Claude Code runs it in an isolated subagent automatically. Do NOT wrap"
  echo "phase skill invocations in an Agent tool call."
  exit 1
fi
