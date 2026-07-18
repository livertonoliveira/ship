#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pipeline.sh <subcommand> [args...]" >&2
  echo "  init      <task-id> [--mode check|fresh|resume] [--config <path>]" >&2
  echo "  dispatch  <scratch-dir> <phase> <tool> <name> <model>" >&2
  echo "  complete  <scratch-dir> <run-number> <phase>..." >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

KNOWN_PHASES="plan dev test perf security review analyze"

is_known_phase() {
  local phase="$1"
  local candidate
  for candidate in $KNOWN_PHASES; do
    [ "$candidate" = "$phase" ] && return 0
  done
  return 1
}

cmd_dispatch() {
  if [ $# -ne 5 ]; then
    usage
    exit 1
  fi
  local scratch_dir="$1"
  local phase="$2"
  local tool="$3"
  local name="$4"
  local model="$5"

  if ! is_known_phase "$phase"; then
    echo "pipeline.sh dispatch: unknown phase: $phase" >&2
    exit 1
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '| %s | %s | %s | %s | %s |\n' "$phase" "$tool" "$name" "$model" "$ts" >> "$scratch_dir/dispatch-log.md"
  echo "▶ Fase: $phase | tool=$tool | name=$name | model=$model"
}

cmd_complete() {
  if [ $# -lt 3 ]; then
    usage
    exit 1
  fi
  local scratch_dir="$1"
  local run_number="$2"
  shift 2

  local files=()
  local phase
  for phase in "$@"; do
    files+=("$scratch_dir/phase-status-$phase.md")
  done

  local output
  if ! output="$(bash "$HOOK_DIR/status-consolidate.sh" "$run_number" "${files[@]}")"; then
    exit 1
  fi

  printf '%s\n' "$output" >> "$scratch_dir/phase-status.md"
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  init)
    exec bash "$HOOK_DIR/run-init.sh" "$@" ;;
  dispatch)
    cmd_dispatch "$@" ;;
  complete)
    cmd_complete "$@" ;;
  *)
    usage
    exit 1 ;;
esac
