#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: test-layer.sh classify <path>..." >&2
  echo "  Prints '<layer>\\t<path>' per argument; layer is unit|integration|e2e|unknown." >&2
  echo "usage: test-layer.sh matches <layer> <path>" >&2
  echo "  Exits 0 when <path> classifies as <layer>." >&2
}

# Path-shaped layer signals only — no stack-specific assumptions. Order is
# load-bearing: an e2e file usually also sits under a generic `test/` root, and
# `*.integration.spec.ts` also ends in `.spec.ts`, so the most specific marker
# has to win or every layer collapses into `unit`.
classify_one() {
  local path="$1" base
  base="${path##*/}"
  case "$path" in
    *e2e*|*E2E*|*end-to-end*|*end_to_end*|*cypress*|*playwright*)
      printf 'e2e' ; return 0 ;;
  esac
  case "$base" in
    *.e2e-spec.*|*.e2e.*|*.e2e_*) printf 'e2e' ; return 0 ;;
  esac
  case "$path" in
    *integration*|*Integration*|*int-test*|*inttest*|*/it/*)
      printf 'integration' ; return 0 ;;
  esac
  case "$base" in
    *.integration.*|*.int.*|*_integration_*) printf 'integration' ; return 0 ;;
  esac
  case "$path" in
    *unit*|*Unit*) printf 'unit' ; return 0 ;;
  esac
  case "$base" in
    *.unit.*) printf 'unit' ; return 0 ;;
  esac
  printf 'unknown'
}

cmd_classify() {
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    printf '%s\t%s\n' "$(classify_one "$p")" "$p"
  done
}

cmd_matches() {
  local layer="$1" path="$2"
  [ "$(classify_one "$path")" = "$layer" ]
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local sub="$1"; shift
  case "$sub" in
    classify) [ $# -ge 1 ] || { usage; exit 1; }; cmd_classify "$@" ;;
    matches)  [ $# -eq 2 ] || { usage; exit 1; }; cmd_matches "$1" "$2" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
