#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDIATION="$SCRIPT_DIR/../remediation.sh"
VERIFY="$SCRIPT_DIR/../remediation-verify.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

field() { printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-; }

make_config() {
  printf '# Config\n\n- Artifact language: en\n' > "$1/config.md"
}

seed_review_finding() {
  local scratch="$1" sev="$2" title="$3" file="$4"
  printf '### [%s] %s\n- **File:** %s\n' "$sev" "$title" "$file" >> "$scratch/review-findings.md"
}

seed_static_failure() {
  local scratch="$1"
  printf '| static | #1 | t | - | fail | 0 | 0 | 0 | 0 | |\n' > "$scratch/phase-status-static.md"
  printf '# Static Failures\n\nTS2304\n' > "$scratch/static-failures.md"
}

seed_test_failure() {
  local scratch="$1"
  printf '| test | #1 | t | - | fail | 0 | 0 | 0 | 0 | |\n' > "$scratch/phase-status-test.md"
  printf '# Test Failures\n\n- src/a.test.ts (1 failure)\n' > "$scratch/test-failures.md"
}

test_empty_scratch_yields_no_items() {
  local name="a scratch dir with nothing to fix produces an empty batch"
  local d; d="$(mktemp -d)"
  local out; out="$(bash "$REMEDIATION" "$d")"
  if [ "$(field "$out" items)" = "0" ] && grep -q 'No items' "$d/remediation.md"; then
    log_pass "$name"
  else
    log_fail "$name (items=$(field "$out" items))"
  fi
  rm -rf "$d"
}

test_every_detector_lands_in_one_batch() {
  local name="typecheck, suite and findings are collected into a single batch"
  local d; d="$(mktemp -d)"
  seed_static_failure "$d"
  seed_test_failure "$d"
  seed_review_finding "$d" HIGH "Race condition on idempotency" "src/a.ts"
  seed_review_finding "$d" MEDIUM "Duplicated pre-lock query" "src/b.ts"
  local out; out="$(bash "$REMEDIATION" "$d")"
  if [ "$(field "$out" items)" = "4" ] \
    && [ "$(field "$out" deterministic)" = "2" ] \
    && [ "$(field "$out" subjective)" = "2" ] \
    && [ "$(grep -c '^### R' "$d/remediation.md")" = "4" ] \
    && grep -q '^R1|deterministic|static|' "$d/remediation-items.txt" \
    && grep -q '|finding|review|high|src/a.ts|race-condition-on-idempotency$' "$d/remediation-items.txt"; then
    log_pass "$name"
  else
    log_fail "$name (items=$(field "$out" items) det=$(field "$out" deterministic) subj=$(field "$out" subjective))"
  fi
  rm -rf "$d"
}

test_passing_phases_contribute_nothing() {
  local name="a green static/test row contributes no deterministic item"
  local d; d="$(mktemp -d)"
  printf '| static | #1 | t | - | pass | 0 | 0 | 0 | 0 | |\n' > "$d/phase-status-static.md"
  printf '| test | #1 | t | - | pass | 0 | 0 | 0 | 0 | |\n' > "$d/phase-status-test.md"
  printf '# Static Failures\n' > "$d/static-failures.md"
  local out; out="$(bash "$REMEDIATION" "$d")"
  if [ "$(field "$out" deterministic)" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (deterministic=$(field "$out" deterministic))"
  fi
  rm -rf "$d"
}

test_resolved_items_clear_the_phase_row() {
  local name="findings marked resolved are subtracted from the phase row"
  local d; d="$(mktemp -d)"
  make_config "$d"
  seed_review_finding "$d" HIGH "Race condition on idempotency" "src/a.ts"
  seed_review_finding "$d" MEDIUM "Duplicated pre-lock query" "src/b.ts"
  bash "$REMEDIATION" "$d" >/dev/null
  printf -- '- R1: resolved\n- R2: resolved\n' > "$d/remediation-verify.md"
  local out; out="$(bash "$VERIFY" "$d" --config "$d/config.md")"
  if [ "$(field "$out" resolved)" = "2" ] && [ "$(field "$out" unresolved)" = "0" ] \
    && grep -qE '^\| review \|.*\| pass \| 0 \| 0 \| 0 \| 0 \|' "$d/phase-status-review.md"; then
    log_pass "$name"
  else
    log_fail "$name (out=$out row=$(cat "$d/phase-status-review.md"))"
  fi
  rm -rf "$d"
}

test_unresolved_items_survive_in_the_row() {
  local name="an unresolved finding keeps its severity in the rewritten phase row"
  local d; d="$(mktemp -d)"
  make_config "$d"
  seed_review_finding "$d" HIGH "Race condition on idempotency" "src/a.ts"
  seed_review_finding "$d" MEDIUM "Duplicated pre-lock query" "src/b.ts"
  bash "$REMEDIATION" "$d" >/dev/null
  printf -- '- R1: unresolved — the race is still reachable\n- R2: resolved\n' > "$d/remediation-verify.md"
  local out; out="$(bash "$VERIFY" "$d" --config "$d/config.md")"
  if [ "$(field "$out" resolved)" = "1" ] && [ "$(field "$out" unresolved)" = "1" ] \
    && [ "$(field "$out" unresolved_ids)" = "R1" ] \
    && grep -qE '^\| review \|.*\| fail \| 0 \| 1 \| 0 \| 0 \|' "$d/phase-status-review.md"; then
    log_pass "$name"
  else
    log_fail "$name (out=$out row=$(cat "$d/phase-status-review.md"))"
  fi
  rm -rf "$d"
}

test_silence_counts_as_unresolved() {
  local name="an item the confirmation pass never answered counts as unresolved"
  local d; d="$(mktemp -d)"
  make_config "$d"
  seed_review_finding "$d" HIGH "Race condition on idempotency" "src/a.ts"
  bash "$REMEDIATION" "$d" >/dev/null
  : > "$d/remediation-verify.md"
  local out; out="$(bash "$VERIFY" "$d" --config "$d/config.md")"
  if [ "$(field "$out" unresolved)" = "1" ] \
    && grep -qE '^\| review \|.*\| fail \| 0 \| 1 \|' "$d/phase-status-review.md"; then
    log_pass "$name"
  else
    log_fail "$name (out=$out)"
  fi
  rm -rf "$d"
}

test_deterministic_items_are_not_scored_by_the_agent() {
  local name="deterministic items are excluded from the confirmation tally — re-running the checks is their verdict"
  local d; d="$(mktemp -d)"
  make_config "$d"
  seed_static_failure "$d"
  bash "$REMEDIATION" "$d" >/dev/null
  : > "$d/remediation-verify.md"
  local out; out="$(bash "$VERIFY" "$d" --config "$d/config.md")"
  if [ "$(field "$out" resolved)" = "0" ] && [ "$(field "$out" unresolved)" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (out=$out)"
  fi
  rm -rf "$d"
}

test_empty_scratch_yields_no_items
test_every_detector_lands_in_one_batch
test_passing_phases_contribute_nothing
test_resolved_items_clear_the_phase_row
test_unresolved_items_survive_in_the_row
test_silence_counts_as_unresolved
test_deterministic_items_are_not_scored_by_the_agent

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
