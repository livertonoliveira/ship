#!/usr/bin/env bash

# Blocking-dependency gate for a single ship:run.
#
# A task's `## Deps` block names other tasks that must land before this one.
# /ship:graph enforces it structurally — a node is admitted only once its
# dependency's PR is MERGED on the forge — but a solo `ship:run` had no
# equivalent: it would plan and implement against a base that does not contain
# the dependency, silently absorbing the other task's scope into this task's
# diff. The planner did notice, and wrote it as prose under `## Map Divergences`
# in the artifact language; no machine reads prose, so the run dispatched the
# implementer with the reason "dispatching the implementer" and nothing else.
#
# The split of labor here is deliberate. Resolving "did MOB-1234 land?" needs a
# Linear token or the forge, which this script has neither of — so the caller
# (pipeline.sh, executed by the run skill) fetches the facts and writes them to
# `deps-state.tsv`. Every decision made from those facts is here, in bash.
#
# Files under <scratch>:
#   deps-state.tsv   <ID>\t<merged|pending>   — written by the run skill
#   deps-ack.txt     one acked <ID> per line  — never reset on resume
#
# Verbs: ids | unresolved | pending | ack | extract

set -euo pipefail

usage() {
  echo "usage: deps-gate.sh <ids|unresolved|pending|ack> <scratch-dir> [--plan <plan.md>]" >&2
  echo "       deps-gate.sh extract --spec <file> [--task <task-id>]" >&2
  echo "  ids         every blocking dependency declared for this task" >&2
  echo "  unresolved  ids with no state line in deps-state.tsv yet" >&2
  echo "  pending     ids not merged and not acked — the gate's trigger" >&2
  echo "  ack         record every currently pending id as acked, print them" >&2
  echo "  extract     the canonical '## Deps' parse, scoped to --task when given" >&2
}

# The canonical extraction: every bare line under `## Deps`, until the next
# heading, minus the `none` sentinel. With --task, scoped to that task's `###`
# section (tasks.md, the shape /ship:graph consumes); without it, the whole file
# (the per-task spec slice `ship:run` stages in the scratch dir).
extract_deps() {
  local file="$1" task="${2:-}"
  [ -f "$file" ] || return 0
  if [ -n "$task" ]; then
    awk -v task="$task" '
      $0 ~ "^###+[[:space:]]+" task "([[:space:]]|$)" { intask = 1; indeps = 0; next }
      intask && /^###+[[:space:]]/ { intask = 0; indeps = 0 }
      intask && /^##[[:space:]]+Deps[[:space:]]*$/ { indeps = 1; next }
      intask && /^#/ { indeps = 0 }
      indeps {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/`/, "")
        if ($0 == "" || tolower($0) == "none") next
        print
      }
    ' "$file"
  else
    awk '
      /^##[[:space:]]+Deps[[:space:]]*$/ { indeps = 1; next }
      /^#/ { indeps = 0 }
      indeps {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/`/, "")
        if ($0 == "" || tolower($0) == "none") next
        print
      }
    ' "$file"
  fi
}

# The planner's own channel. A divergence that points at another task is worth
# exactly one machine-readable token — anything richer would be a second spec
# format to keep in sync, and anything less (severity words in the artifact
# language) is what already failed. Everything else in that section stays free
# prose for `ship:develop` to absorb during its confrontation pass.
extract_plan_deps() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^##[[:space:]]+Map Divergences[[:space:]]*$/ { insection = 1; next }
    /^##[[:space:]]/ { insection = 0 }
    insection && /DEP[[:space:]]+[^[:space:]]/ {
      line = $0
      sub(/^.*DEP[[:space:]]+/, "", line)
      sub(/[[:space:]].*$/, "", line)
      gsub(/[`,]/, "", line)
      sub(/[.:;—-]+$/, "", line)
      if (line != "") print line
    }
  ' "$file"
}

# A malformed id is dropped rather than failing the run: the gate exists to stop
# work on a real unmet dependency, and turning a typo into a hard stop would
# make the planner's optional channel a way to brick the pipeline.
#
# The shape rule is deliberately stricter than "no punctuation": a task id has a
# separator (TASK-001, MOB-3013, task_auth). A bare word like `M2` is a
# milestone name, and one that reached here as a dep stopped a graph node on
# "unmet blocking dependencies: M2" — a gate on something that is not a task.
sanitize_ids() {
  local id self="${1:-}"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!a-zA-Z0-9_-]*) continue ;;
      *[-_]*) ;;
      *) continue ;;
    esac
    [ "$id" = "$self" ] && continue
    printf '%s\n' "$id"
  done
}

collect_ids() {
  local scratch="$1" plan="${2:-}" self
  self="$(basename "$scratch")"
  {
    extract_deps "$scratch/spec.md"
    extract_plan_deps "$plan"
  } | sanitize_ids "$self" | awk '!seen[$0]++'
}

state_of() {
  local scratch="$1" id="$2" st
  st="$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$scratch/deps-state.tsv" 2>/dev/null | tail -1)"
  printf '%s' "$(printf '%s' "$st" | tr -d '[:space:]')"
}

is_acked() {
  local scratch="$1" id="$2"
  [ -f "$scratch/deps-ack.txt" ] || return 1
  grep -qx "$id" "$scratch/deps-ack.txt"
}

cmd_ids() {
  collect_ids "$1" "${2:-}"
}

cmd_unresolved() {
  local scratch="$1" plan="${2:-}" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -z "$(state_of "$scratch" "$id")" ] && printf '%s\n' "$id"
  done < <(collect_ids "$scratch" "$plan")
  return 0
}

# Fail closed, the same rule the worker-status enum uses: a state that is
# missing, empty or outside the enum is the least permissive outcome. An
# unresolvable dependency is exactly the case worth asking about.
cmd_pending() {
  local scratch="$1" plan="${2:-}" id st
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    st="$(state_of "$scratch" "$id")"
    [ "$st" = "merged" ] && continue
    is_acked "$scratch" "$id" && continue
    printf '%s\n' "$id"
  done < <(collect_ids "$scratch" "$plan")
  return 0
}

cmd_ack() {
  local scratch="$1" plan="${2:-}" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$id" >> "$scratch/deps-ack.txt"
    printf '%s\n' "$id"
  done < <(cmd_pending "$scratch" "$plan")
  return 0
}

main() {
  local verb="${1:-}"
  [ -n "$verb" ] || { usage; exit 1; }
  shift || true

  if [ "$verb" = "extract" ]; then
    local spec="" task=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --spec) spec="${2:-}"; shift 2 ;;
        --task) task="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
      esac
    done
    [ -n "$spec" ] || { usage; exit 1; }
    extract_deps "$spec" "$task"
    exit 0
  fi

  local scratch="" plan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) plan="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done
  [ -n "$scratch" ] || { usage; exit 1; }
  [ -d "$scratch" ] || { echo "deps-gate: scratch dir not found: $scratch" >&2; exit 1; }

  case "$verb" in
    ids) cmd_ids "$scratch" "$plan" ;;
    unresolved) cmd_unresolved "$scratch" "$plan" ;;
    pending) cmd_pending "$scratch" "$plan" ;;
    ack) cmd_ack "$scratch" "$plan" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
