#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: run-init.sh <task-id> [--mode check|fresh|resume] [--config <path>]" >&2
  echo "  check  (default): detect an interrupted prior run; exit 3 with a RESUME report" >&2
  echo "                    when dispatch rows exist, otherwise perform a fresh init" >&2
  echo "  fresh:  initialize the scratch dir from scratch (overwrites canonical files)" >&2
  echo "  resume: preserve existing state; only re-capture diff.md and re-classify" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

TASK_ID=""
MODE="check"
CONFIG="ship/config.md"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *)
      if [ -z "$TASK_ID" ]; then TASK_ID="$1"; else usage; exit 1; fi
      shift ;;
  esac
done

if [ -z "$TASK_ID" ]; then
  usage
  exit 1
fi
case "$TASK_ID" in
  *[!a-zA-Z0-9_-]*)
    echo "run-init.sh: invalid task id (allowed: [a-zA-Z0-9_-]): $TASK_ID" >&2
    exit 1 ;;
esac
case "$MODE" in
  check|fresh|resume) ;;
  *) usage; exit 1 ;;
esac

SCRATCH=".context/ship-run/$TASK_ID"
DISPATCH_LOG="$SCRATCH/dispatch-log.md"
PHASE_STATUS="$SCRATCH/phase-status.md"

phases_in() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -F'|' 'NR > 2 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 != "" && $2 != "Phase" && $2 !~ /^-+$/) print $2 }' "$f" | sort -u
}

if [ "$MODE" = "check" ]; then
  rows=0
  if [ -f "$DISPATCH_LOG" ]; then
    rows="$(awk -F'|' 'NR > 2 && NF > 2 { p = $2; gsub(/[[:space:]]/, "", p); if (p != "" && p !~ /^-+$/) n++ } END { print n + 0 }' "$DISPATCH_LOG")"
  fi
  if [ "$rows" -gt 0 ]; then
    dispatched="$(phases_in "$DISPATCH_LOG" | tr '\n' ',' | sed 's/,$//')"
    completed="$(phases_in "$PHASE_STATUS" | tr '\n' ',' | sed 's/,$//')"
    unfinished="$(comm -23 <(phases_in "$DISPATCH_LOG") <(phases_in "$PHASE_STATUS") | tr '\n' ',' | sed 's/,$//')"
    last="$(tail -1 "$DISPATCH_LOG" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $2 " " $6 }')"
    printf 'RESUME\n'
    printf 'last_dispatch=%s\n' "$last"
    printf 'dispatched=%s\n' "${dispatched:-none}"
    printf 'completed=%s\n' "${completed:-none}"
    printf 'unfinished=%s\n' "${unfinished:-none}"
    exit 3
  fi
  MODE="fresh"
fi

mkdir -p "$SCRATCH"

if [ "$MODE" = "fresh" ]; then
  if [ ! -f "$CONFIG" ]; then
    echo "run-init.sh: config not found: $CONFIG (run /ship:init first)" >&2
    exit 1
  fi

  field() {
    grep -m1 -E "^- $1:" "$CONFIG" 2>/dev/null | sed -E "s/^- $1:[[:space:]]*//" || true
  }
  {
    printf '# Stack\n\n'
    for f in Language Runtime Framework 'Test runner' 'Package manager'; do
      v="$(field "$f")"
      printf -- '- %s: %s\n' "$f" "${v:-unknown}"
    done
  } > "$SCRATCH/stack.md"

  printf '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n' > "$PHASE_STATUS"
  printf '# Dispatch Log\n\n| Phase | Tool | Name | Model | Timestamp |\n|-------|------|------|-------|-----------|\n' > "$DISPATCH_LOG"

  git rev-parse HEAD > "$SCRATCH/pre-quality-snapshot.sha"
  bash "$HOOK_DIR/snapshot-files.sh" snapshot "$SCRATCH/pre-develop-files.txt"
fi

bash "$HOOK_DIR/capture-diff.sh" "$SCRATCH/diff.md"
CLASS_OUT="$(bash "$HOOK_DIR/diff-classify.sh" "$SCRATCH/diff.md" "$SCRATCH/diff-class.txt")"

printf 'INIT %s\n' "$MODE"
printf 'scratch=%s\n' "$SCRATCH"
printf 'diff_class=%s\n' "$CLASS_OUT"
