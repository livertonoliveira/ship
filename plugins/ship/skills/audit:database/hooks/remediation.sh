#!/usr/bin/env bash

# remediation.sh <scratch-dir>
#
# Assemble the ONE remediation batch for a verification round: the deterministic
# failures (typecheck/lint, red suite, coverage regression) and every gate
# finding, in a single artifact with stable per-item ids.
#
# The pipeline used to fix these in three serialized loops — static, then test,
# then gate — because each stage blocked the next, so the full list of required
# adjustments never existed at one point in time. This script is that list. One
# fix agent consumes it; one confirmation pass checks it item by item.
#
# Writes:
#   <scratch>/remediation.md         the batch the fix agent reads
#   <scratch>/remediation-items.txt  R<N>|<kind>|<phase>|<severity>|<file>|<slug>
# Prints:
#   items=<N> deterministic=<N> subjective=<N>

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scratch="${1:-}"
if [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
  echo "usage: remediation.sh <scratch-dir>" >&2
  exit 1
fi

# Gate column of a per-phase row: "| phase | run | ts | files | gate | ... |".
row_gate() {
  local f="$scratch/phase-status-$1.md"
  [ -f "$f" ] || return 0
  awk -F'|' '/^\|/ { g = $6; gsub(/^[ \t]+|[ \t]+$/, "", g); print g; exit }' "$f"
}

items_file="$scratch/remediation-items.txt"
: > "$items_file"

n=0
deterministic=0
subjective=0

body_deterministic=""
body_findings=""

add_deterministic() {
  local phase="$1" label="$2" source_file="$3"
  n=$((n + 1))
  deterministic=$((deterministic + 1))
  printf 'R%s|deterministic|%s|critical||%s\n' "$n" "$phase" "$label" >> "$items_file"
  body_deterministic="${body_deterministic}### R$n — $phase ($label)
Source: $source_file

"
}

if [ "$(row_gate static)" = "fail" ] && [ -f "$scratch/static-failures.md" ]; then
  add_deterministic static "typecheck/lint" "$scratch/static-failures.md"
fi
if [ "$(row_gate test)" = "fail" ] && [ -f "$scratch/test-failures.md" ]; then
  add_deterministic test "red suite" "$scratch/test-failures.md"
fi
if [ -f "$scratch/test-regression.md" ]; then
  add_deterministic test-generate "coverage regression" "$scratch/test-regression.md"
fi

# Findings come from the same identity extractor the pipeline uses elsewhere, so
# an item id maps back to exactly one finding across the fix and the confirmation.
detail_for() {
  case "$1" in
    review)   printf '%s/review-findings.md' "$scratch" ;;
    perf)     printf '%s/perf-findings.md' "$scratch" ;;
    security) printf '%s/security-findings.json' "$scratch" ;;
    *)        printf '%s' "$scratch" ;;
  esac
}

while IFS='|' read -r phase severity file slug; do
  [ -n "${phase:-}" ] || continue
  n=$((n + 1))
  subjective=$((subjective + 1))
  printf 'R%s|finding|%s|%s|%s|%s\n' "$n" "$phase" "$severity" "$file" "$slug" >> "$items_file"
  body_findings="${body_findings}### R$n — [$severity] $phase · ${file:-<no file>}
Finding: $slug
Detail: $(detail_for "$phase")

"
done < <(bash "$HOOK_DIR/findings-identity.sh" "$scratch" 2>/dev/null || true)

{
  printf '# Remediation Batch\n\n'
  printf 'Every item below was detected in the SAME verification round — this is the\n'
  printf 'complete list of adjustments this round requires. Fix all of them in one pass,\n'
  printf 'then stop. A confirmation pass will check each item by its id.\n\n'
  printf 'Minimal source fixes only: no unrelated refactors, no comments, no spec IDs in\n'
  printf 'code or test names. Read each item Source/Detail file for the actual error.\n\n'
  if [ -n "$body_deterministic" ]; then
    printf '## Deterministic failures\n\n%s' "$body_deterministic"
  fi
  if [ -n "$body_findings" ]; then
    printf '## Findings\n\n%s' "$body_findings"
  fi
  if [ "$n" -eq 0 ]; then
    printf 'No items.\n'
  fi
} > "$scratch/remediation.md"

printf 'items=%s\n' "$n"
printf 'deterministic=%s\n' "$deterministic"
printf 'subjective=%s\n' "$subjective"
