#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${REPO_ROOT}/plugins/ship/skills/run/SKILL.md"

VIOLATIONS=0

is_allowlisted() {
  grep -qE 'pipeline\.sh (dispatch|complete)' <<< "$1"
}

report_hits() {
  local label="$1"
  local hits="$2"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! is_allowlisted "$line"; then
      echo "VIOLATION: ${label}"
      echo "  $line"
      echo ""
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done <<< "$hits"
}

echo "Scanning ${TARGET} for manual bookkeeping anti-patterns..."
echo ""

if [[ ! -f "$TARGET" ]]; then
  echo "VIOLATION: ${TARGET} not found"
  exit 1
fi

dispatch_log_hits=$(grep -nE '\|\s*<phase>\s*\|\s*<(Skill\|Agent|Agent\|Skill)>\s*\|' "$TARGET" || true)
report_hits "dispatch-log line-format instruction found" "$dispatch_log_hits"

manual_append_hits=$(grep -inE '(append|write)( a| the| your)?( new)? row (to|in|into)[^.]*phase-status\.md|manually append[^.]*phase-status\.md' "$TARGET" || true)
report_hits "manual-append instruction targeting phase-status.md found" "$manual_append_hits"

timestamp_hits=$(grep -inE 'iso-?8601[^.]*timestamp|timestamp[^.]*iso-?8601' "$TARGET" || true)
report_hits "ISO-8601 timestamp format instruction found" "$timestamp_hits"

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — no manual bookkeeping anti-pattern found in compiled run/SKILL.md."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} manual bookkeeping anti-pattern(s) found."
  echo ""
  echo "The compiled orchestrator must only call 'pipeline.sh dispatch' before a"
  echo "phase tool call and 'pipeline.sh complete' / 'status-consolidate.sh' after"
  echo "a dispatch barrier, then act on what the script reports. It must never"
  echo "instruct the reader to hand-construct a dispatch-log row, hand-append a"
  echo "phase-status.md row, or reproduce an ISO-8601 timestamp manually."
  exit 1
fi
