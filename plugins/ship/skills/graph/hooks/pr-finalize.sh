#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pr-finalize.sh <task-id> [--keep-context] [--feature <name>]" >&2
  echo "  Deterministic ship:pr closing steps: remove the task's scratch dir (never the" >&2
  echo "  shared parent) and, in local mode, archive the feature folder under" >&2
  echo "  ship/changes/archive/<date>-<name>." >&2
  echo "Prints: context=cleaned|preserved|absent  archive=<path>|none" >&2
}

main() {
  local task="" keep="" feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-context) keep="1"; shift ;;
      --feature) feature="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$task" ]; then task="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$task" ]; then usage; exit 1; fi
  case "$task" in
    *[!a-zA-Z0-9_-]*)
      echo "pr-finalize.sh: invalid task id (allowed: [a-zA-Z0-9_-]): $task" >&2
      exit 1 ;;
  esac
  case "$feature" in
    *[!a-zA-Z0-9_.-]*)
      echo "pr-finalize.sh: invalid feature name (allowed: [a-zA-Z0-9_.-]): $feature" >&2
      exit 1 ;;
  esac

  local scratch=".context/ship-run/$task" context="absent"
  if [ -d "$scratch" ]; then
    if [ -n "$keep" ]; then
      context="preserved"
    else
      rm -rf "$scratch"
      context="cleaned"
    fi
  fi

  local archive="none"
  if [ -n "$feature" ] && [ -d "ship/changes/$feature" ]; then
    mkdir -p ship/changes/archive
    archive="ship/changes/archive/$(date +%Y-%m-%d)-$feature"
    mv "ship/changes/$feature" "$archive"
  fi

  printf 'context=%s\n' "$context"
  printf 'archive=%s\n' "$archive"
}

main "$@"
