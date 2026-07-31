#!/usr/bin/env bash

set -euo pipefail

# Everything in a plan that is DERIVED rather than DECIDED.
#
# The planner used to transcribe two lists out of the spec by hand — every
# scenario with its layer, and every file the spec touches — and plan-validate.sh
# then checked the transcription against the spec it came from. Five of its nine
# checks existed only to catch transcription slips, and a slip cost a full replan
# round each time. Worse, a spec that names two different scenarios with one id
# has NO valid transcription at all, so the loop could not converge on it.
#
# Generating those lists here removes the failure instead of retrying it: the
# planner never enumerates, so it cannot drop, duplicate or mis-layer anything.
# What is left for it is what it is actually for — grouping files into modules,
# ordering them, and naming test paths per the repo's conventions.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: plan-scaffold.sh <scratch-dir> [--config <path>]" >&2
  echo "  Reads <scratch-dir>/spec.md and writes <scratch-dir>/plan-scaffold.md:" >&2
  echo "  a File Inventory and a Test Contract with one slot per scenario" >&2
  echo "  OCCURRENCE, layer taken from its own tag. Never fails on spec content." >&2
}

# One record per scenario occurrence: id|layer|title|arrange|act|assert.
#
# Keyed by occurrence and not by id on purpose. Two scenarios sharing an id is a
# spec defect, but it is not this stage's to reject — the plan still has to be
# producible, and one slot per occurrence is the only shape that can hold both.
scenario_records() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    function flush(  t) {
      if (id == "") return
      gsub(/\|/, "/", title); gsub(/\|/, "/", arrange)
      gsub(/\|/, "/", act);   gsub(/\|/, "/", assert)
      print id "|" layer "|" title "|" arrange "|" act "|" assert
      id = ""; layer = ""; title = ""; arrange = ""; act = ""; assert = ""
    }
    function add(bucket, text) {
      if (bucket == "arrange") arrange = arrange (arrange ? "; " : "") text
      else if (bucket == "act") act = act (act ? "; " : "") text
      else if (bucket == "assert") assert = assert (assert ? "; " : "") text
    }
    # Tags accumulate instead of each line starting over: Gherkin lets them span
    # several lines, and treating the second line as a new scenario dropped the
    # title AND the layer — which then silently defaulted to unit. A scenario
    # tagged @e2e on its own line would have been planned, generated and run as
    # a unit test, with nothing anywhere reporting it.
    /^[[:space:]]*@/ {
      tags = tags " " $0
      next
    }
    /^[[:space:]]*(Scenario Outline|Scenario|Cenário|Esquema do Cenário)[[:space:]]*:/ {
      flush()
      if (match(tags, /@SC-[0-9]+/)) id = substr(tags, RSTART, RLENGTH)
      if (tags ~ /@unit/) layer = "unit"
      else if (tags ~ /@integration/) layer = "integration"
      else if (tags ~ /@e2e/) layer = "e2e"
      else layer = ""
      tags = ""
      t = $0
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", t)
      title = t
      bucket = ""
      next
    }
    /^[[:space:]]*(Given|Dado|Dada|Dados|Dadas|Background|Contexto)[[:space:]]/ {
      bucket = "arrange"; add(bucket, trim($0)); next
    }
    /^[[:space:]]*(When|Quando)[[:space:]]/ { bucket = "act"; add(bucket, trim($0)); next }
    /^[[:space:]]*(Then|Então|Entao)[[:space:]]/ { bucket = "assert"; add(bucket, trim($0)); next }
    /^[[:space:]]*(And|But|E|Mas)[[:space:]]/ { if (bucket != "") add(bucket, trim($0)); next }
    /^##[[:space:]]/ { flush(); tags = ""; bucket = "" }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    END { flush() }
  ' "$spec" 2>/dev/null || true
}

# `## Files` entries the spec owns. Same extraction plan-validate.sh used to run
# against the spec directly; centralised here so the two can never disagree.
spec_files() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  awk '
    /^## Files/ { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^[[:space:]]*(-[[:space:]]*)?(create|modify|Âncora|Ancora|Anchor)/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/`/, "", line)
      if (line ~ /^(Âncora|Ancora|Anchor)[[:space:]]*:/) next
      if (!match(line, /^(create|modify)[[:space:]]+/)) next
      verb = substr(line, 1, RLENGTH - 1)
      sub(/[[:space:]]+$/, "", verb)
      sub(/^(create|modify)[[:space:]]+/, "", line)
      sub(/[[:space:]]*(—|–|--).*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") next
      print verb "\t" line
    }
  ' "$spec" 2>/dev/null | sort -u || true
}

# Scenario ids carrying more than one distinct title. Reported, never rejected:
# the run must still produce a plan, and the place to stop this is spec time,
# where sc-crossref.sh gates it.
duplicate_ids() {
  local records="$1"
  printf '%s\n' "$records" | awk -F'|' '
    NF >= 3 { key = $1 "|" $3; if (!(key in seen)) { seen[key] = 1; n[$1]++ } }
    END { for (id in n) if (n[id] > 1) print id "\t" n[id] }
  ' | sort || true
}

# A layer the config switched off has no worker, so a slot in it is coverage that
# never runs. Surfaced next to the slot rather than failing later in validation.
disabled_layers() {
  local config="$1"
  [ -n "$config" ] && [ -f "$config" ] || return 0
  [ -f "$HOOK_DIR/test-scope.sh" ] || return 0
  grep -qE '^-[[:space:]]*test:[[:space:]]*disabled' "$config" && return 0
  bash "$HOOK_DIR/test-scope.sh" --config "$config" 2>/dev/null \
    | grep '^skip=' | sed 's/^skip=//' || true
}

main() {
  local scratch="" config=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        config="${2:-}"
        [ -n "$config" ] || { echo "plan-scaffold: --config requires a path" >&2; exit 1; }
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done
  [ -n "$scratch" ] || { usage; exit 1; }

  local spec="$scratch/spec.md" out="$scratch/plan-scaffold.md"
  if [ ! -f "$spec" ]; then
    echo "plan-scaffold: spec not found: $spec" >&2
    exit 1
  fi

  local records files dups skip
  records="$(scenario_records "$spec")"
  files="$(spec_files "$spec")"
  dups="$(duplicate_ids "$records")"
  skip=" $(disabled_layers "$config") "

  local task_id
  task_id="$(basename "$scratch")"

  {
    printf '# Plan Scaffold — %s\n\n' "$task_id"
    printf 'Generated from spec.md. The lists below are complete: assign every row, never add or drop one.\n'

    printf '\n## File Inventory\n\n'
    if [ -n "$files" ]; then
      local verb path missing
      while IFS=$'\t' read -r verb path; do
        [ -n "$path" ] || continue
        missing=""
        [ "$verb" = "modify" ] && [ ! -e "$path" ] && missing=" — ABSENT on disk; correct the path or log it under ## Map Divergences"
        printf -- '- %s (%s) -> M?%s\n' "$path" "$verb" "$missing"
      done <<< "$files"
    else
      printf 'None — the spec carries no ## Files map; derive the file set from the design.\n'
    fi

    printf '\n## Test Contract\n\n'
    if [ -n "$records" ]; then
      # The leading S<n> is the slot's identity for the rest of the pipeline.
      # Matching on the id alone cannot separate two scenarios that share one,
      # and matching on the title would make the plan hinge on the planner
      # re-typing accented prose byte for byte.
      local id layer title arrange act assert note n=0
      while IFS='|' read -r id layer title arrange act assert; do
        [ -n "$id" ] || continue
        n=$((n + 1))
        note=""
        # An untagged scenario has to land somewhere, but defaulting in silence
        # is how a scenario ends up in a layer nobody chose. Say so in the slot.
        if [ -z "$layer" ]; then
          layer="unit"
          note=" — NO LAYER TAG in the spec; defaulted to unit, confirm or retag"
        fi
        case "$skip" in *" $layer "*) note="$note — LAYER DISABLED in ## Test Scope; move it or enable the layer" ;; esac
        printf '### S%s %s (%s) -> %s -> TBD%s\n' "$n" "$id" "$title" "$layer" "$note"
        printf -- '- arrange/act/assert: %s / %s / %s\n' "${arrange:-—}" "${act:-—}" "${assert:-—}"
      done <<< "$records"
    else
      printf 'None — the spec carries no tagged scenarios; derive slots from the Acceptance Criteria.\n'
    fi

    if [ -n "$dups" ]; then
      printf '\n## Spec Defects\n\n'
      local did dn
      while IFS=$'\t' read -r did dn; do
        [ -n "$did" ] || continue
        printf -- '- %s labels %s behaviorally distinct scenarios — each got its own slot above, but the ids need splitting at spec time.\n' "$did" "$dn"
      done <<< "$dups"
    fi
  } > "$out"

  printf 'scaffold=%s\n' "$out"
  printf 'files=%s\n' "$(printf '%s' "$files" | grep -c . || true)"
  printf 'slots=%s\n' "$(printf '%s' "$records" | grep -c . || true)"
  [ -n "$dups" ] && printf 'spec_defects=%s\n' "$(printf '%s' "$dups" | grep -c . || true)"
  return 0
}

main "$@"
