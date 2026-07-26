#!/usr/bin/env bash

# The hard regression for graph mode. Homolog is a mandatory stop: with three
# tasks in flight that becomes three asynchronous approvals, and the parallelism
# gain dies there. `homolog-mode.txt == defer` must therefore produce a real
# report and emit `done` — not `ask`, and not a dispatch of the homolog skill.
#
# It must also stay OFF by default: a single-task /ship:run keeps asking.

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

# A repo whose config disables every phase that would need an agent, so `next`
# walks straight to homolog with real (if minimal) artifacts behind it.
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
    cat > ship/config.md <<'EOF'
# Ship Config

## Project
- Name: Fixture
- Type: prompt-toolkit

## Pipeline Phases
- dev: disabled
- test: disabled
- perf: disabled
- security: disabled
- review: disabled
- homolog: enabled

## Conventions
- Artifact language: English
EOF
  )
}

# Drive `next` to the point where the task context is staged, so the following
# call lands on the homolog decision.
drive_to_homolog() {
  local dir="$1" task="$2"
  (
    cd "$dir"
    bash "$PIPELINE" next "$task" >/dev/null 2>&1 || true
    printf '# Spec\n\nAC-01: fixture.\n' > ".context/ship-run/$task/spec.md"
    printf '# Design\n\nnone.\n' > ".context/ship-run/$task/design.md"
  )
}

test_default_still_asks_for_acceptance() {
  local name="without the marker, homolog still stops for the user (the default is unchanged)"
  local dir out task="homologdefaulttask"
  dir="$(mktemp -d)"
  setup_repo "$dir"
  drive_to_homolog "$dir" "$task"
  out="$(cd "$dir" && bash "$PIPELINE" next "$task")"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "homolog" ] && [ "$(field "$out" action)" = "work" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_defer_emits_done_not_ask() {
  local name="with homolog-mode=defer, next emits done — never a stop for acceptance"
  local dir out task="homologdefertask"
  dir="$(mktemp -d)"
  setup_repo "$dir"
  drive_to_homolog "$dir" "$task"
  printf 'defer\n' > "$dir/.context/ship-run/$task/homolog-mode.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next "$task")"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "done" ] && [ "$(field "$out" action)" = "done" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_defer_writes_a_real_report() {
  local name="defer writes homolog-report.md with the gate index and the wall clock"
  local dir report task="homologreporttask"
  dir="$(mktemp -d)"
  setup_repo "$dir"
  drive_to_homolog "$dir" "$task"
  printf 'defer\n' > "$dir/.context/ship-run/$task/homolog-mode.txt"
  (cd "$dir" && bash "$PIPELINE" next "$task" >/dev/null)
  report="$(cat "$dir/.context/ship-run/$task/homolog-report.md" 2>/dev/null || true)"
  rm -rf "$dir"

  if printf '%s' "$report" | grep -q '^# Homolog' \
    && printf '%s' "$report" | grep -q '## Gate by phase' \
    && printf '%s' "$report" | grep -q '## Wall clock' \
    && printf '%s' "$report" | grep -q '## Consolidated findings'; then
    log_pass "$name"
  else
    log_fail "$name (report was empty or missing sections)"
  fi
}

test_defer_marks_the_task_approved() {
  local name="defer records the approval as 'deferred', distinguishable from a real approval"
  local dir approved task="homologapprovedtask"
  dir="$(mktemp -d)"
  setup_repo "$dir"
  drive_to_homolog "$dir" "$task"
  printf 'defer\n' > "$dir/.context/ship-run/$task/homolog-mode.txt"
  (cd "$dir" && bash "$PIPELINE" next "$task" >/dev/null)
  approved="$(cat "$dir/.context/ship-run/$task/homolog-approved.txt" 2>/dev/null || true)"
  rm -rf "$dir"

  if [ "$approved" = "deferred" ]; then
    log_pass "$name"
  else
    log_fail "$name (got '$approved')"
  fi
}

test_defer_never_dispatches_the_homolog_skill() {
  local name="defer costs no LLM: the homolog skill is never dispatched"
  local dir dispatched task="homolognollmtask"
  dir="$(mktemp -d)"
  setup_repo "$dir"
  drive_to_homolog "$dir" "$task"
  printf 'defer\n' > "$dir/.context/ship-run/$task/homolog-mode.txt"
  (cd "$dir" && bash "$PIPELINE" next "$task" >/dev/null)
  dispatched="$(grep -c 'ship:homolog' "$dir/.context/ship-run/$task/dispatch-log.md" 2>/dev/null || true)"
  rm -rf "$dir"

  if [ "${dispatched:-0}" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (dispatch-log.md has $dispatched homolog row(s))"
  fi
}

test_unknown_marker_falls_back_to_asking() {
  local name="an unrecognized marker value falls back to the normal acceptance stop"
  local dir out task="homologbogustask"
  dir="$(mktemp -d)"
  setup_repo "$dir"
  drive_to_homolog "$dir" "$task"
  printf 'sometimes\n' > "$dir/.context/ship-run/$task/homolog-mode.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next "$task")"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "homolog" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)')"
  fi
}

test_default_still_asks_for_acceptance
test_defer_emits_done_not_ask
test_defer_writes_a_real_report
test_defer_marks_the_task_approved
test_defer_never_dispatches_the_homolog_skill
test_unknown_marker_falls_back_to_asking

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
