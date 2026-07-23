#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_SCRIPT="$SCRIPT_DIR/../pipeline.sh"

pass_count=0
fail_count=0

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

write_dispatch_log() {
  local f="$1"; shift
  {
    printf '# Dispatch Log\n\n| Phase | Tool | Name | Model | Timestamp |\n|-------|------|------|-------|-----------|\n'
    printf '%s\n' "$@"
  } > "$f"
}

write_phase_status() {
  local f="$1"; shift
  {
    printf '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n'
    printf '%s\n' "$@"
  } > "$f"
}

test_dispatched_phase_missing_status_row_blocks_gate() {
  local name="a dispatched phase with no phase-status.md row blocks the gate (no silent partial PASS)"
  local dir out rc=0
  dir="$(mktemp -d)"
  write_dispatch_log "$dir/dispatch-log.md" \
    "| plan | skipped | - | - | 2026-07-19T21:30:52Z |" \
    "| dev | Skill | ship:develop | sonnet | 2026-07-19T21:30:52Z |" \
    "| test | Skill | ship:test | sonnet | 2026-07-19T21:33:53Z |"
  write_phase_status "$dir/phase-status.md" \
    "| dev | #1 | 2026-07-19T21:30:00Z | 3 | PASS | 0 | 0 | 0 | 0 | typecheck+lint clean |"

  out="$(bash "$PIPELINE_SCRIPT" gate "$dir" 2>&1)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 1 ]; then
    log_fail "$name (exit code was $rc, expected 1)"
    return
  fi
  if ! grep -q "missing phase-status.md row(s): test" <<< "$out"; then
    log_fail "$name (missing expected error message, got: $out)"
    return
  fi
  log_pass "$name"
}

test_completing_the_missing_row_unblocks_the_gate() {
  local name="once the missing phase-status.md row is appended, the gate evaluates normally"
  local dir out rc=0
  dir="$(mktemp -d)"
  write_dispatch_log "$dir/dispatch-log.md" \
    "| dev | Skill | ship:develop | sonnet | 2026-07-19T21:30:52Z |" \
    "| test | Skill | ship:test | sonnet | 2026-07-19T21:33:53Z |"
  write_phase_status "$dir/phase-status.md" \
    "| dev | #1 | 2026-07-19T21:30:00Z | 3 | PASS | 0 | 0 | 0 | 0 | |" \
    "| test | #1 | 2026-07-19T21:40:00Z | - | pass | 0 | 0 | 0 | 0 | |"

  out="$(bash "$PIPELINE_SCRIPT" gate "$dir")" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc, expected 0 — got: $out)"
    return
  fi
  if [ "$out" != $'decision=PASS\naction=continue' ]; then
    log_fail "$name (got: $out)"
    return
  fi
  log_pass "$name"
}

test_skipped_dispatch_rows_never_block_the_gate() {
  local name="rows dispatched with tool=skipped (e.g. plan) never require a phase-status.md row"
  local dir out rc=0
  dir="$(mktemp -d)"
  write_dispatch_log "$dir/dispatch-log.md" \
    "| plan | skipped | - | - | 2026-07-19T21:30:52Z |" \
    "| dev | Skill | ship:develop | sonnet | 2026-07-19T21:30:52Z |"
  write_phase_status "$dir/phase-status.md" \
    "| dev | #1 | 2026-07-19T21:30:00Z | 3 | PASS | 0 | 0 | 0 | 0 | |"

  out="$(bash "$PIPELINE_SCRIPT" gate "$dir")" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc, expected 0 — got: $out)"
    return
  fi
  log_pass "$name"
}

test_real_plan_dispatch_never_blocks_the_gate() {
  local name="a real (non-skipped) plan dispatch never blocks the gate — plan is not gate-scored"
  local dir out rc=0
  dir="$(mktemp -d)"
  write_dispatch_log "$dir/dispatch-log.md" \
    "| plan | Skill | ship:plan | sonnet | 2026-07-19T21:29:00Z |" \
    "| dev | Skill | ship:develop | sonnet | 2026-07-19T21:30:52Z |"
  write_phase_status "$dir/phase-status.md" \
    "| dev | #1 | 2026-07-19T21:30:00Z | 3 | PASS | 0 | 0 | 0 | 0 | |"

  out="$(bash "$PIPELINE_SCRIPT" gate "$dir")" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_fail "$name (exit code was $rc, expected 0 — got: $out)"
    return
  fi
  log_pass "$name"
}

test_missing_quality_phase_dispatch_blocks_gate() {
  local name="a quality phase (security) dispatched but never completed blocks the gate even amid other complete phases"
  local dir out rc=0
  dir="$(mktemp -d)"
  write_dispatch_log "$dir/dispatch-log.md" \
    "| dev | Skill | ship:develop | sonnet | 2026-07-19T21:30:52Z |" \
    "| perf | Agent | ship-perf | sonnet | 2026-07-19T21:33:53Z |" \
    "| security | Agent | ship-security | sonnet | 2026-07-19T21:33:53Z |" \
    "| review | Skill | ship:review | sonnet | 2026-07-19T21:33:53Z |"
  write_phase_status "$dir/phase-status.md" \
    "| dev | #1 | 2026-07-19T21:30:00Z | 3 | PASS | 0 | 0 | 0 | 0 | |" \
    "| perf | #1 | 2026-07-19T21:35:00Z | 3 | pass | 0 | 0 | 0 | 0 | |" \
    "| review | #1 | 2026-07-19T21:35:00Z | 3 | pass | 0 | 0 | 0 | 0 | |"

  out="$(bash "$PIPELINE_SCRIPT" gate "$dir" 2>&1)" || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 1 ]; then
    log_fail "$name (exit code was $rc, expected 1 — got: $out)"
    return
  fi
  if ! grep -q "missing phase-status.md row(s): security" <<< "$out"; then
    log_fail "$name (missing expected error message, got: $out)"
    return
  fi
  log_pass "$name"
}

test_dispatched_phase_missing_status_row_blocks_gate
test_completing_the_missing_row_unblocks_the_gate
test_skipped_dispatch_rows_never_block_the_gate
test_real_plan_dispatch_never_blocks_the_gate
test_missing_quality_phase_dispatch_blocks_gate

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
