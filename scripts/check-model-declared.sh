#!/usr/bin/env bash
# check-model-declared.sh
#
# Verifies that every SKILL.md under src/skills/ declares a `model:` field
# in its frontmatter (the YAML block delimited by the two opening `---` lines).
#
# Without this lint, a new skill can ship without a model declaration and the
# omission goes unnoticed — exactly what happened with audit:run before it was
# fixed. Requiring an explicit model: "haiku" or model: "sonnet" makes routing
# decisions auditable and enforces the model-transparency convention.
#
# Usage: ./scripts/check-model-declared.sh
# Exit code 0 = clean; exit code 1 = violation(s) found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_BASE="${REPO_ROOT}/src/skills"

VIOLATIONS=0

check_file() {
  local file="$1"
  # Parse the frontmatter block (content between the first two `---` delimiters)
  # and check whether a `model:` field is present.
  awk -v file="$file" '
    /^---$/ {
      dashes++
      # Stop reading after the closing --- of the frontmatter block
      if (dashes == 2) { exit }
      next
    }
    dashes == 1 && /^model:/ { found = 1 }
    END {
      if (!found) {
        printf "VIOLATION: %s\n", file
        printf "  No '"'"'model:'"'"' field in frontmatter\n\n"
        exit 1
      }
      exit 0
    }
  ' "$file" || return 1
  return 0
}

echo "Scanning src/skills/**/SKILL.md for missing model: declaration..."
echo ""

while IFS= read -r -d '' file; do
  # Make the path relative to REPO_ROOT for cleaner output
  rel_file="${file#"${REPO_ROOT}/"}"
  if ! check_file "$rel_file"; then
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done < <(find "$SKILLS_BASE" -name "SKILL.md" -print0)

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — all skills declare model: in their frontmatter."
  exit 0
else
  echo "Found ${VIOLATIONS} violation(s). All skills must declare model: \"haiku\" or model: \"sonnet\"."
  exit 1
fi
