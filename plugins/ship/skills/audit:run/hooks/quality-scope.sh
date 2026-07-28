#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: quality-scope.sh <class> --phases \"<candidate quality phases>\" [--scratch <dir>] [--config <path>]" >&2
  echo "  <class>     trivial | minor | normal | large" >&2
  echo "  --phases    space-separated candidate quality phases among: perf security review" >&2
  echo "              (intersected with ship/config.md — a disabled phase never runs, even if listed here)" >&2
  echo "  --scratch   write PASS skip rows (via findings-gate) for skipped phases" >&2
  echo "  --config    config path — source of truth for Pipeline Profile/Phases (default ship/config.md)" >&2
  echo "Prints: run=<phases to dispatch>  skip=<phases marked PASS>  log=<message>" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
QUALITY_ORDER="perf security review"

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# Deterministic re-derivation of Pipeline Profile + Pipeline Phases from
# ship/config.md — never trust a caller-supplied --phases list on its own,
# since it may come from a model's (possibly wrong) reading of the config.
section_lines() {
  local config="$1" header="$2"
  [ -f "$config" ] || return 0
  awk -v h="$header" '
    $0 ~ "^## " h "$" { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^-[[:space:]]*[A-Za-z0-9_-]+:/ { print }
  ' "$config"
}

profile_name() {
  local config="$1" v
  # trailing `|| true`: a no-match grep exits non-zero and (with pipefail)
  # would abort the script under `set -e` on an absent/empty section.
  v="$(section_lines "$config" "Pipeline Profile" | grep -m1 -E '^-[[:space:]]*profile:' | sed -E 's/^-[[:space:]]*profile:[[:space:]]*//' | awk '{print $1}' || true)"
  printf '%s' "${v:-standard}"
}

phase_override() {
  local config="$1" phase="$2"
  section_lines "$config" "Pipeline Phases" | grep -m1 -E "^-[[:space:]]*$phase:" | sed -E "s/^-[[:space:]]*$phase:[[:space:]]*//" | awk '{print $1}' || true
}

profile_default() {
  local profile="$1" phase="$2"
  case "$phase" in
    perf|security)
      case "$profile" in strict) printf enabled ;; *) printf disabled ;; esac ;;
    review)
      case "$profile" in lite) printf disabled ;; *) printf enabled ;; esac ;;
  esac
}

# `Security Focus -> categories: none` is documented (src/patterns/security-categories.md)
# as equivalent to `security: disabled` — re-derive it the same way Pipeline
# Phases is re-derived, so a misread of this field can't leave security scanning
# a diff the user explicitly opted out of (or vice versa).
security_focus_category() {
  local config="$1" v
  v="$(section_lines "$config" "Security Focus" | grep -m1 -E '^-[[:space:]]*categories:' | sed -E 's/^-[[:space:]]*categories:[[:space:]]*//' | awk '{print $1}' || true)"
  printf '%s' "${v:-all}"
}

# perf/security/review are config-gated (profile default + Pipeline Phases
# override, override wins; security is additionally forced off by
# `Security Focus: categories: none`).
config_enabled_quality_phases() {
  local config="$1"
  if [ ! -f "$config" ]; then
    printf '%s' "$QUALITY_ORDER"
    return
  fi
  local profile state p out=""
  profile="$(profile_name "$config")"
  for p in perf security review; do
    state="$(phase_override "$config" "$p")"
    [ -z "$state" ] && state="$(profile_default "$profile" "$p")"
    if [ "$p" = "security" ] && [ "$(security_focus_category "$config")" = "none" ]; then
      state="disabled"
    fi
    [ "$state" = "enabled" ] && out="$out $p"
  done
  printf '%s' "${out# }"
}

main() {
  local class="" phases="" scratch="" config="ship/config.md"

  while [ $# -gt 0 ]; do
    case "$1" in
      --phases) phases="$2"; shift 2 ;;
      --scratch) scratch="$2"; shift 2 ;;
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$class" ]; then class="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$class" ]; then usage; exit 1; fi
  case "$class" in
    trivial|minor|normal|large) ;;
    *) echo "quality-scope.sh: unknown class: $class" >&2; exit 1 ;;
  esac

  # Enabled quality phases: candidate --phases ∩ config-derived enablement,
  # restricted to the known set and canonical order. A phase disabled in
  # ship/config.md (directly or via Pipeline Profile) never runs, regardless
  # of what --phases lists.
  local config_enabled
  config_enabled="$(config_enabled_quality_phases "$config")"

  local -a enabled=()
  local p
  for p in $QUALITY_ORDER; do
    if in_list "$p" $phases && in_list "$p" $config_enabled; then enabled+=("$p"); fi
  done

  # Decide run vs skip per class.
  local -a run=() skip=()
  local log
  case "$class" in
    trivial)
      skip=(${enabled[@]+"${enabled[@]}"})
      log="Diff trivial — fases de qualidade puladas"
      ;;
    minor)
      for p in ${enabled[@]+"${enabled[@]}"}; do
        case "$p" in
          security) run+=("$p") ;;
          *) skip+=("$p") ;;
        esac
      done
      log="Diff minor — perf/review pulados, security mantido"
      ;;
    normal|large)
      run=(${enabled[@]+"${enabled[@]}"})
      log="Diff $class — fases de qualidade completas"
      ;;
  esac

  # Write PASS skip rows deterministically (reuse findings-gate — zero counts → PASS).
  if [ -n "$scratch" ]; then
    for p in ${skip[@]+"${skip[@]}"}; do
      bash "$HOOK_DIR/findings-gate.sh" "$p" \
        --notes "diff $class — pulado" \
        --scratch "$scratch" --config "$config" >/dev/null
    done
  fi

  # Fan-out depth: a small diff is already a fraction of one screen, so slicing it
  # across nested sub-agents costs more in per-agent startup than it saves. Only a
  # `large` diff earns nested fan-out; everything smaller runs each quality phase
  # flat (the phase agent analyzes the whole diff in-context, no sub-agents).
  local depth
  case "$class" in
    large) depth="nested" ;;
    *) depth="flat" ;;
  esac

  printf 'run=%s\n' "$(printf '%s ' ${run[@]+"${run[@]}"} | sed 's/ *$//')"
  printf 'skip=%s\n' "$(printf '%s ' ${skip[@]+"${skip[@]}"} | sed 's/ *$//')"
  printf 'depth=%s\n' "$depth"
  printf 'log=%s\n' "$log"
}

main "$@"
