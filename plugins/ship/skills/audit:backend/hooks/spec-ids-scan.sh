#!/usr/bin/env bash

set -euo pipefail

# Blocks a spec artifact that gives one scenario id to two different behaviors.
#
# sc-crossref.sh has caught this since it was written, but it only ran because a
# line of prose in ship:spec's SKILL asked the model to run it — so when the
# model did not, a spec shipped with one id on three distinct scenarios. Nothing
# downstream could recover: a plan needs one slot per behavior, and one id
# cannot key three, so the run failed validation on every replan.
#
# A PostToolUse hook is the one place the check cannot be skipped. It fires on
# the write itself, before the artifact reaches a reader.
#
# Reach: files written to disk. Linear-mode issues go out over MCP and never
# touch Write/Edit, so they are not covered here — ship:spec's own gate and
# plan-scaffold.sh's `## Spec Defects` section remain the net for those.

usage() {
  echo "usage: spec-ids-scan.sh <file>   (or PostToolUse JSON on stdin)" >&2
}

# A Ship spec artifact: the local-mode files, or anything carrying a Scenario
# Index. Ordinary prose that merely mentions an id is not scanned — the check
# needs tagged Gherkin to have anything to compare.
is_spec_artifact() {
  local p="$1"
  case "$p" in
    */.context/*) return 1 ;;
    */ship/changes/*/tasks.md|*/ship/changes/*/proposal.md) return 0 ;;
    ship/changes/*/tasks.md|ship/changes/*/proposal.md) return 0 ;;
  esac
  case "$p" in
    *.md) grep -qE '^[[:space:]]*@SC-[0-9]+[[:space:]]+@AC-[0-9]+' "$p" 2>/dev/null && return 0 ;;
  esac
  return 1
}

# "<id>\t<n>" for every id tagging more than one distinct scenario title.
duplicate_ids() {
  local f="$1"
  awk '
    /^[[:space:]]*@/ {
      if (match($0, /@SC-[0-9]+/)) { id = substr($0, RSTART, RLENGTH); pending = 1 }
      next
    }
    /^[[:space:]]*(Scenario Outline|Scenario|Cenário|Esquema do Cenário)[[:space:]]*:/ {
      if (!pending || id == "") next
      t = $0
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", t)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      key = id SUBSEP t
      if (!(key in seen)) { seen[key] = 1; n[id]++; sample[id] = sample[id] (sample[id] ? "; " : "") t }
      pending = 0
      next
    }
    END { for (i in n) if (n[i] > 1) print i "\t" n[i] "\t" sample[i] }
  ' "$f" 2>/dev/null | sort || true
}

scan() {
  local f="$1" dups
  [ -f "$f" ] || return 1
  is_spec_artifact "$f" || return 1
  dups="$(duplicate_ids "$f")"
  [ -n "$dups" ] || return 1
  printf '%s\n' "$dups"
  return 0
}

if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
  if out="$(scan "$1")"; then
    printf '%s\n' "$out"
    exit 2
  fi
  echo "spec-ids-scan: clean."
  exit 0
fi

input="$(cat)"
file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$file_path" ] || exit 0

if out="$(scan "$file_path")"; then
  {
    echo "Ship spec gate: one scenario id labels more than one behavior in the file you just wrote."
    echo
    echo "Duplicated ids (id, count, titles):"
    printf '%s\n' "$out" | while IFS=$'\t' read -r id n titles; do
      printf '  %s — %s scenarios: %s\n' "$id" "$n" "$titles"
    done
    echo
    echo "Why this blocks: each scenario needs its own test slot, and one id can key only one."
    echo "A plan for this spec cannot be produced at all, so the failure would surface much later,"
    echo "as a pipeline that fails plan validation on every retry."
    echo
    echo "Required fix: renumber so every distinct scenario has its own id, in the Gherkin tags AND"
    echo "in the Scenario Index. Ids are spec-global and stable — extend the sequence, never reuse."
  } >&2
  exit 2
fi

exit 0
