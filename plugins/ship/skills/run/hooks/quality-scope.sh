#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: quality-scope.sh <class> --phases \"<enabled quality phases>\" [--scratch <dir>] [--config <path>]" >&2
  echo "  <class>     trivial | minor | normal | large" >&2
  echo "  --phases    space-separated enabled quality phases among: perf security review analyze" >&2
  echo "  --scratch   write PASS skip rows (via findings-gate) for skipped phases" >&2
  echo "  --config    config path forwarded to findings-gate (default ship/config.md)" >&2
  echo "Prints: run=<phases to dispatch>  skip=<phases marked PASS>  log=<message>" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
QUALITY_ORDER="perf security review analyze"

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
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

  # Enabled quality phases, restricted to the known set and canonical order.
  local -a enabled=()
  local p
  for p in $QUALITY_ORDER; do
    if in_list "$p" $phases; then enabled+=("$p"); fi
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
          security|analyze) run+=("$p") ;;
          *) skip+=("$p") ;;
        esac
      done
      log="Diff minor — perf/review pulados, security/analyze mantidos"
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

  printf 'run=%s\n' "$(printf '%s ' ${run[@]+"${run[@]}"} | sed 's/ *$//')"
  printf 'skip=%s\n' "$(printf '%s ' ${skip[@]+"${skip[@]}"} | sed 's/ *$//')"
  printf 'log=%s\n' "$log"
}

main "$@"
