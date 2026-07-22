#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: analyze-precheck.sh <spec-file> <diff-file> [--scratch <dir>] [--test-scope <spec>] [--repo-root <dir>] [--config <path>] [--findings-gate <path>]" >&2
  echo "  Runs the correlation engine and decides whether the analyze Agent is needed." >&2
  echo "  A fully clean correlation (no unimplemented/uncertain/uncovered items, no orphans" >&2
  echo "  or duplicates) can only yield low-severity TERM findings in-context and has no" >&2
  echo "  gray-zone to escalate — the gate is guaranteed PASS, so the Agent is skipped and" >&2
  echo "  the PASS row is written deterministically. Anything else defers to the Agent." >&2
  echo "  Prints: agent=skip | agent=run" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

SPEC=""
DIFF=""
SCRATCH=""
TEST_SCOPE=""
REPO_ROOT="."
CONFIG="ship/config.md"
FINDINGS_GATE="$HOOK_DIR/findings-gate.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch) SCRATCH="$2"; shift 2 ;;
    --test-scope) TEST_SCOPE="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --findings-gate) FINDINGS_GATE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *)
      if [ -z "$SPEC" ]; then SPEC="$1"
      elif [ -z "$DIFF" ]; then DIFF="$1"
      else usage; exit 1
      fi
      shift ;;
  esac
done

if [ -z "$SPEC" ] || [ -z "$DIFF" ]; then usage; exit 1; fi

# Defer to the Agent (which owns the in-context correlation fallback) rather than
# guess — never skip on uncertainty. Any failure to obtain a clean summary here
# prints agent=run.
run_agent() { printf 'agent=run\n'; exit 0; }

correlate_args=("$SPEC" "$DIFF" --repo-root "$REPO_ROOT")
[ -n "$SCRATCH" ] && correlate_args+=(--scratch "$SCRATCH")
[ -n "$TEST_SCOPE" ] && correlate_args+=(--test-scope "$TEST_SCOPE")

JSON="$(bash "$HOOK_DIR/analyze-correlate.sh" "${correlate_args[@]}" 2>/dev/null)" || run_agent
case "$JSON" in
  *'"summary"'*) ;;
  *) run_agent ;;
esac

# Pull one integer field out of a JSON object slice.
field() { printf '%s' "$1" | grep -oE "\"$2\":[0-9]+" | grep -oE '[0-9]+' | head -1; }

req="$(printf '%s' "$JSON" | grep -oE '"requirements":\{[^}]*\}')"
crit="$(printf '%s' "$JSON" | grep -oE '"criteria":\{[^}]*\}')"
scen="$(printf '%s' "$JSON" | grep -oE '"scenarios":\{[^}]*\}')"

# Every count that could produce a gate-affecting finding (critical/high/medium)
# or a gray-zone item needing in-context escalation. All zero → guaranteed PASS.
total=0
for v in \
  "$(field "$req" unimplemented)" "$(field "$req" uncertain)" \
  "$(field "$crit" uncovered)" "$(field "$crit" uncertain)" \
  "$(field "$scen" uncovered)" "$(field "$scen" uncertain)" \
  "$(field "$JSON" orphans)" "$(field "$JSON" duplicates)"; do
  total=$((total + ${v:-0}))
done

if [ "$total" -ne 0 ]; then run_agent; fi

# Clean correlation: write the PASS row deterministically and skip the Agent.
if [ -n "$SCRATCH" ]; then
  bash "$FINDINGS_GATE" analyze \
    --notes "correlação limpa — sem drift" \
    --scratch "$SCRATCH" --config "$CONFIG" >/dev/null
fi
printf 'agent=skip\n'
