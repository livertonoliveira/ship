#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: test-scope.sh [--config <path>]" >&2
  echo "  Deterministically re-derives ## Test Scope from ship/config.md." >&2
  echo "  A layer with no explicit entry (or a missing config/section) defaults to enabled." >&2
  echo "Prints: run=<enabled layers>  skip=<disabled layers>" >&2
}

LAYER_ORDER="unit integration e2e"

section_lines() {
  local config="$1" header="$2"
  [ -f "$config" ] || return 0
  awk -v h="$header" '
    $0 ~ "^## " h "$" { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^-[[:space:]]*[A-Za-z0-9_-]+:/ { print }
  ' "$config"
}

layer_state() {
  local config="$1" layer="$2"
  # trailing `|| true`: a no-match grep exits non-zero and (with pipefail)
  # would abort the script under `set -e` on an absent/empty section.
  section_lines "$config" "Test Scope" | grep -m1 -E "^-[[:space:]]*$layer:" | sed -E "s/^-[[:space:]]*$layer:[[:space:]]*//" | awk '{print $1}' || true
}

main() {
  local config="ship/config.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  local l state run="" skip=""
  for l in $LAYER_ORDER; do
    state="$(layer_state "$config" "$l")"
    if [ -z "$state" ] || [ "$state" = "enabled" ]; then
      run="$run $l"
    else
      skip="$skip $l"
    fi
  done

  printf 'run=%s\n' "${run# }"
  printf 'skip=%s\n' "${skip# }"
}

main "$@"
