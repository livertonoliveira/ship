#!/usr/bin/env bash

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Ship spec gate — Linear MCP counterpart of spec-ids-scan.sh.
#
# spec-ids-scan.sh blocks a spec that gives one @SC id to two behaviorally
# distinct scenarios, but only on PostToolUse for Write|Edit. A Linear-mode
# spec never touches Write/Edit — ship:spec authors it over MCP
# (mcp__linear-server__save_document / save_issue) — so that matcher cannot
# see it. That gap is exactly how a spec reached the pipeline with a
# scenario id reused across several behaviorally distinct scenarios: nothing
# blocked the save, so the defect only surfaced downstream as plan.md
# failing validation and being rewritten on every replan.
#
# PreToolUse on those two MCP tools closes the gap: the block lands before
# the save leaves the box, same contract as guard-destructive-git.sh
# (exit 2, reason on stderr, no runtime beyond bash/awk/sed).
#
# Reach: `content` (save_document) and `description` (save_issue) — the
# fields a full document is written through, covering create and any
# full-content update. A `patch` call carries only incremental text and this
# hook has no way to fetch the document's existing content back from Linear,
# so it cannot catch a patch that duplicates an id already living in the doc
# — it only catches a duplicate formed within the patch call itself.


usage() {
  echo "usage: spec-ids-scan-mcp.sh   (PreToolUse JSON on stdin)" >&2
}

# "<id>\t<n>\t<titles>" for every id tagging more than one distinct scenario title.
# Same rule as spec-ids-scan.sh's duplicate_ids, reading stdin instead of a file
# since the content here comes decoded out of JSON, never as a path on disk.
duplicate_ids() {
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
  ' 2>/dev/null | sort || true
}

report_and_block() {
  local tool="$1" out="$2"
  {
    echo "Ship spec gate: one scenario id labels more than one behavior in the $tool call you just made."
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
}

main() {
  local input tool_name field=""
  input="$(cat)"
  [ -n "$input" ] || exit 0

  tool_name="$(printf '%s' "$input" | json_find tool_name)"
  case "$tool_name" in
    mcp__linear-server__save_document) field="content" ;;
    mcp__linear-server__save_issue) field="description" ;;
    *) exit 0 ;;
  esac

  local decoded out
  decoded="$(printf '%s' "$input" | json_find "$field")"
  if [ -n "$decoded" ]; then
    out="$(printf '%s' "$decoded" | duplicate_ids)"
    if [ -n "$out" ]; then
      report_and_block "$tool_name" "$out"
    fi
  fi

  local patch_text
  patch_text="$(printf '%s' "$input" | json_find_all new_string)
$(printf '%s' "$input" | json_find_all text)"
  if [ -n "$patch_text" ]; then
    out="$(printf '%s' "$patch_text" | duplicate_ids)"
    if [ -n "$out" ]; then
      report_and_block "$tool_name (patch)" "$out"
    fi
  fi

  exit 0
}

main
