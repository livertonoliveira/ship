#!/usr/bin/env bash
# e2e-validate.sh — deterministic, offline validation of Ship's build mechanics.
#
# Asserts the invariants that the build + pattern-reference system must hold,
# without invoking any LLM. Fast and free; run on every change and in CI.
#
# Checks:
#   1. Clean rebuild from src/ produces no drift in plugins/ship/{skills,agents}.
#   2. No unresolved @ship / @@ship tokens remain in built skills or agents.
#   3. Every ${CLAUDE_SKILL_DIR}/<path> referenced in a built skill has its
#      bundled file present next to that skill.
#   4. Bundled lazy patterns are self-contained (no @ship/@@ship inside).
#   5. Built skills stay within their size budget (regression guard).
#   6. The existing structural lint scripts pass.
#
# Exit 0 = all green; non-zero = at least one violation.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SKILLS="plugins/ship/skills"
AGENTS="plugins/ship/agents"
fail=0
note() { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

echo "Ship E2E — deterministic validation"
echo

# --- 1. Build drift -----------------------------------------------------------
( cd plugins/ship && npm run build >/dev/null 2>&1 ) || { bad "build failed"; exit 1; }
if git diff --quiet -- "$SKILLS" "$AGENTS"; then
  ok "build drift: src/ and plugins/ in sync"
else
  bad "build drift: plugins/ differs from a clean build of src/ — commit the rebuild"
  git diff --stat -- "$SKILLS" "$AGENTS" | sed 's/^/    /'
fi

# --- 2. No unresolved @ship / @@ship in built output --------------------------
stray=$(grep -rlE '@@?ship/[A-Za-z0-9_./-]+\.md' "$SKILLS" "$AGENTS" 2>/dev/null || true)
if [ -z "$stray" ]; then
  ok "no unresolved @ship/@@ship tokens in built output"
else
  bad "unresolved @ship/@@ship tokens in:"; echo "$stray" | sed 's/^/    /'
fi

# --- 3. Lazy refs resolve to a bundled file -----------------------------------
broken=$(while IFS= read -r skill; do
  skilldir=$(dirname "$skill")
  grep -oE '\$\{CLAUDE_SKILL_DIR\}/[A-Za-z0-9_./-]+\.md' "$skill" 2>/dev/null \
    | sed 's#${CLAUDE_SKILL_DIR}/##' | sort -u | while IFS= read -r rel; do
        [ -n "$rel" ] && [ ! -f "$skilldir/$rel" ] && echo "$skill → $rel"
      done
done < <(find "$SKILLS" -name SKILL.md))
if [ -z "$broken" ]; then
  ok "every \${CLAUDE_SKILL_DIR} lazy ref has its bundled file"
else
  bad "lazy refs without a bundled file:"; echo "$broken" | sed 's/^/    /'
fi

# --- 4. Bundled lazy patterns are self-contained ------------------------------
dirty=$(find "$SKILLS" -path '*/patterns/*.md' -exec grep -lE '@@?ship/' {} + 2>/dev/null || true)
if [ -z "$dirty" ]; then
  ok "bundled lazy patterns are self-contained"
else
  bad "bundled patterns still contain @ship/@@ship refs:"; echo "$dirty" | sed 's/^/    /'
fi

# --- 5. Size budgets (regression guard) ---------------------------------------
# Budget = generous ceiling; trip only on a real regression.
check_budget() {
  local f="$1" limit="$2"
  [ -f "$f" ] || { bad "missing built file: $f"; return; }
  local n; n=$(wc -l < "$f")
  if [ "$n" -le "$limit" ]; then ok "size $f: $n ≤ $limit"; else bad "size $f: $n > $limit (regression)"; fi
}
check_budget "$SKILLS/run/SKILL.md" 1300
check_budget "$SKILLS/homolog/SKILL.md" 500
check_budget "$SKILLS/pr/SKILL.md" 600

# --- 6. Existing structural lints ---------------------------------------------
for s in check-no-agent-wraps-skill check-no-audit-in-pipeline check-model-declared; do
  if bash "scripts/$s.sh" >/dev/null 2>&1; then ok "lint: $s"; else bad "lint: $s failed"; fi
done

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mE2E validate: PASS\033[0m"; else echo -e "\033[31mE2E validate: FAIL\033[0m"; fi
exit "$fail"
