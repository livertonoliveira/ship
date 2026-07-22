#!/usr/bin/env bash

# findings-identity.sh <scratch-dir>
#
# Emit one stable identity line per finding across every findings artifact in
# <scratch-dir>, as:  <phase>|<severity>|<file>|<slug>
#
# The identity is the signal the pipeline's convergence guard needs: it must be
# stable for the SAME finding across re-verify rounds (so line-number churn from
# an intervening fix does not mint a new identity) yet distinct for genuinely
# different findings. So file paths are stripped of their :line suffix and the
# title is slugified.
#
# Extraction is grep/sed/awk only (no jq) for parity with findings-gate.sh and
# rerun-scope.sh. JSON objects that carry no "severity" (e.g. the drift
# escalation log) are ignored — only gate findings have a severity.

set -eu

scratch="${1:-}"
if [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
  echo "usage: findings-identity.sh <scratch-dir>" >&2
  exit 1
fi

# Markdown findings files (### [SEV] Title  +  - **File:** path:line) → identity.
emit_md() {
  local phase="$1" f="$2"
  [ -f "$f" ] || return 0
  awk -v phase="$phase" '
    function slug(s) {
      s = tolower(s); gsub(/[^a-z0-9]+/, "-", s)
      sub(/^-+/, "", s); sub(/-+$/, "", s); return substr(s, 1, 60)
    }
    function normfile(s) {
      sub(/:[0-9]+(-[0-9]+)?[ \t]*$/, "", s)
      gsub(/^[ \t]+|[ \t]+$/, "", s); return s
    }
    function flush() {
      if (have) print phase "|" sev "|" normfile(file) "|" slug(title)
    }
    /^### \[/ {
      flush()
      have = 1; file = ""
      sev = $0; sub(/^### \[/, "", sev); sub(/\].*/, "", sev); sev = tolower(sev)
      title = $0; sub(/^### \[[^]]*\][ \t]*/, "", title)
      next
    }
    /^-[ \t]*\*\*File:\*\*/ {
      if (file == "") { file = $0; sub(/^-[ \t]*\*\*File:\*\*[ \t]*/, "", file) }
      next
    }
    END { flush() }
  ' "$f"
}

# JSON findings files (flat array, or an object with a "findings" array). Only
# objects carrying a "severity" are findings; the drift escalation log has none.
emit_json() {
  local phase="$1" f="$2" content obj sev file slugsrc
  [ -f "$f" ] || return 0
  content="$(tr -d '\n' < "$f")"
  # Drift wraps findings in {"findings":[...],"escalations":[...],...}; isolate
  # the findings array so sibling arrays (escalations have no severity, but a
  # single-object array is not split on "},{" and would otherwise merge in).
  case "$content" in
    *'"findings"'*) content="$(printf '%s' "$content" | sed -E 's/.*"findings":[[:space:]]*\[//; s/\].*//')" ;;
  esac
  # One JSON object per line, then keep the severity-bearing ones.
  { printf '%s' "$content" | sed 's/}[[:space:]]*,[[:space:]]*{/}\
{/g' | grep '"severity"' || true; } | while IFS= read -r obj; do
    sev="$(printf '%s' "$obj" | sed -E 's/.*"severity"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | tr '[:upper:]' '[:lower:]')"
    file="$(printf '%s' "$obj" | grep -oE '"(filePath|file)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
    file="$(printf '%s' "$file" | sed -E 's/:[0-9]+(-[0-9]+)?$//')"
    # Slug source: prefer title, else the drift identifiers, else category.
    slugsrc="$(printf '%s' "$obj" | grep -oE '"(title|requirementId|scenarioId|criterionId|category)"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | tr '\n' '-')"
    slugsrc="$(printf '%s' "$slugsrc" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-60)"
    printf '%s|%s|%s|%s\n' "$phase" "$sev" "$file" "$slugsrc"
  done
}

{
  emit_md   review "$scratch/review-findings.md"
  emit_md   perf   "$scratch/perf-findings.md"
  emit_json security "$scratch/security-findings.json"
  emit_json analyze  "$scratch/drift-findings.json"
} | { grep -v '^[^|]*||' || true; } | sort -u

exit 0
