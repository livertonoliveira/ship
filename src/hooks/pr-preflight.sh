#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pr-preflight.sh [--task <task-id>] [--feature <name>] [--config <path>]" >&2
  echo "  Deterministic ship:pr prerequisites in one call: storage mode, branch state," >&2
  echo "  pending-change count, pipeline profile, local approval marker, gate row summary." >&2
  echo "Prints: storage= branch= on_default_branch= pending_changes= profile= approval=" >&2
  echo "        plus one 'gate_row:' line per phase when the scratch dir exists" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

section_field() {
  local config="$1" section="$2" key="$3"
  [ -f "$config" ] || return 0
  awk -v h="$section" '
    $0 ~ "^## " h "$" { insection = 1; next }
    /^## / { insection = 0 }
    insection { print }
  ' "$config" | grep -m1 -E "^-[[:space:]]*$key:" | sed -E "s/^-[[:space:]]*$key:[[:space:]]*//" | awk '{print $1}' || true
}

main() {
  local task="" feature="" config="ship/config.md"

  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --feature) feature="$2"; shift 2 ;;
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  local storage="local"
  [ "$(section_field "$config" "Linear Integration" "Configured")" = "yes" ] && storage="linear"

  local branch on_default="no"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
  case "$branch" in
    main|master) on_default="yes" ;;
  esac

  local pending
  pending="$(git status --porcelain 2>/dev/null | grep -c . || true)"

  local profile
  profile="$(section_field "$config" "Pipeline Profile" "profile")"
  profile="${profile:-standard}"

  # Local mode: the approval marker lives in the feature's report file. Linear
  # mode: approval lives in issue comments — the caller checks via MCP, so we
  # report 'unknown' rather than guess.
  local approval="unknown"
  if [ "$storage" = "local" ]; then
    approval="absent"
    local report_glob="ship/changes/$feature"
    if [ -n "$feature" ] && [ -d "$report_glob" ]; then
      if grep -rqF -- '- [x] User approves for PR' "$report_glob" 2>/dev/null; then
        approval="present"
      fi
    fi
  fi

  printf 'storage=%s\n' "$storage"
  printf 'branch=%s\n' "$branch"
  printf 'on_default_branch=%s\n' "$on_default"
  printf 'pending_changes=%s\n' "$pending"
  printf 'profile=%s\n' "$profile"
  printf 'approval=%s\n' "$approval"

  if [ -n "$task" ] && [ -f ".context/ship-run/$task/phase-status.md" ]; then
    bash "$HOOK_DIR/pipeline.sh" rows ".context/ship-run/$task" | sed 's/^/gate_row:/'
  fi
}

main "$@"
