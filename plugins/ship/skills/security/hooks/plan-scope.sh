#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: plan-scope.sh <scratch-dir>" >&2
  echo "  Guarantees the plan phase is recorded in the dispatch log: if the planner was" >&2
  echo "  neither dispatched nor already logged as skipped, backfills a 'plan … skipped'" >&2
  echo "  row deterministically (so the plan decision is never lost to a missed LLM step)." >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

main() {
  local scratch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$scratch" ]; then usage; exit 1; fi

  local log="$scratch/dispatch-log.md"
  if [ -f "$log" ] && awk -F'|' '
      NR > 2 { p = $2; gsub(/[[:space:]]/, "", p); if (p == "plan") found = 1 }
      END { exit found ? 0 : 1 }
    ' "$log"; then
    echo "plan=already-recorded"
    return 0
  fi

  bash "$HOOK_DIR/pipeline.sh" dispatch "$scratch" plan - skipped - >/dev/null
  echo "plan=skipped (backfilled)"
}

main "$@"
