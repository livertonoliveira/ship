#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

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

field() {
  printf '%s\n' "$1" | grep "^$2=" | head -1 | sed "s/^$2=//"
}

setup_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    git update-ref refs/remotes/origin/main HEAD
    mkdir -p ship
    printf '# Ship Config\n\n## Pipeline Phases\n- dev: disabled\n- test: disabled\n- perf: disabled\n- security: disabled\n- review: disabled\n- homolog: enabled\n\n## Conventions\n- Artifact language: English\n' > ship/config.md
    bash "$PIPELINE" next T-1 >/dev/null 2>&1 || true
    printf '# Spec\n\nfixture.\n' > .context/ship-run/T-1/spec.md
    printf '# Design\n\nnone.\n' > .context/ship-run/T-1/design.md
  )
}

# A worker the SubagentStart hook recorded as started a moment ago.
start_worker() {
  printf '%s\nagent-1\n' "$(date -u +%s)" > "$1/.context/ship-run/T-1/worker-start-ship-review.txt"
}

test_a_running_worker_keeps_the_run_waiting() {
  local name="next reports waiting, not a phase decision, while a dispatched worker is still running"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  start_worker "$dir"
  out="$(cd "$dir" && SHIP_AWAIT_WORKERS_S=0 bash "$PIPELINE" next T-1)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "waiting" ] && [ "$(field "$out" action)" = "work" ] \
     && printf '%s' "$out" | grep -q 'ship-review' && printf '%s' "$out" | grep -q 'without ending your run'; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
}

test_next_waits_for_the_worker_to_finish() {
  local name="next blocks while the worker runs and carries on once its done marker lands"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  start_worker "$dir"
  ( sleep 6; date -u +%s > "$dir/.context/ship-run/T-1/worker-done-ship-review.txt" ) &
  out="$(cd "$dir" && SHIP_AWAIT_WORKERS_S=30 bash "$PIPELINE" next T-1)"
  wait
  rm -rf "$dir"
  if [ "$(field "$out" state)" != "waiting" ] && [ -n "$(field "$out" state)" ]; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
}

test_a_finished_worker_does_not_hold_the_run() {
  local name="a worker whose done marker is already there costs no wait"
  local dir out start end
  dir="$(mktemp -d)"
  setup_repo "$dir"
  start_worker "$dir"
  sleep 1
  date -u +%s > "$dir/.context/ship-run/T-1/worker-done-ship-review.txt"
  start="$(date +%s)"
  out="$(cd "$dir" && bash "$PIPELINE" next T-1)"
  end="$(date +%s)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" != "waiting" ] && [ $((end - start)) -lt 5 ]; then
    log_pass "$name"
  else
    log_fail "$name (took $((end - start))s, out: $out)"
  fi
}

test_a_worker_that_wrote_its_output_is_finished_without_a_marker() {
  local name="a worker that wrote its output after starting is finished even when no done marker came"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  printf '%s\nagent-2\n' "$(date -u +%s)" > "$dir/.context/ship-run/T-1/worker-start-ship-test-unit.txt"
  sleep 1
  echo "Status: DONE" > "$dir/.context/ship-run/T-1/worker-status-unit.md"
  out="$(cd "$dir" && SHIP_AWAIT_WORKERS_S=0 bash "$PIPELINE" next T-1)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" != "waiting" ]; then log_pass "$name"; else log_fail "$name (out: $out)"; fi
}

test_a_fix_agent_with_its_report_is_finished() {
  local name="the remediation fix agent counts as finished once its report is written"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  printf '%s\nagent-3\n' "$(date -u +%s)" > "$dir/.context/ship-run/T-1/worker-start-ship-remediation-fix.txt"
  sleep 1
  echo "- R1: fixed" > "$dir/.context/ship-run/T-1/remediation-fix-report.md"
  out="$(cd "$dir" && SHIP_AWAIT_WORKERS_S=0 bash "$PIPELINE" next T-1)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" != "waiting" ]; then log_pass "$name"; else log_fail "$name (out: $out)"; fi
}

test_a_stale_start_marker_is_ignored() {
  local name="a start marker older than an hour (a run that died) never holds the pipeline"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  printf '%s\nagent-1\n' "$(( $(date -u +%s) - 7200 ))" > "$dir/.context/ship-run/T-1/worker-start-ship-review.txt"
  out="$(cd "$dir" && SHIP_AWAIT_WORKERS_S=0 bash "$PIPELINE" next T-1)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" != "waiting" ]; then log_pass "$name"; else log_fail "$name (out: $out)"; fi
}

test_a_running_worker_keeps_the_run_waiting
test_next_waits_for_the_worker_to_finish
test_a_finished_worker_does_not_hold_the_run
test_a_stale_start_marker_is_ignored
test_a_fix_agent_with_its_report_is_finished
test_a_worker_that_wrote_its_output_is_finished_without_a_marker

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
