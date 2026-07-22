#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/../pr-preflight.sh"
FINALIZE="$SCRIPT_DIR/../pr-finalize.sh"

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

setup_repo() {
  local dir="$1" linear="$2" profile="$3"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    mkdir ship
    printf '# Config\n\n## Linear Integration\n- Configured: %s\n\n## Pipeline Profile\n- profile: %s\n' "$linear" "$profile" > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A
    git commit -qm init
  ) >/dev/null
}

field() {
  printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-
}

test_preflight_reports_local_state() {
  local name="pr-preflight reports storage, branch state, pending changes, profile and local approval"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" no strict
  mkdir -p "$dir/ship/changes/my-feature"
  printf '## Homologation\n\n- [x] User approves for PR\n' > "$dir/ship/changes/my-feature/report.md"
  echo dirty > "$dir/b.txt"
  local out
  out="$(cd "$dir" && bash "$PREFLIGHT" --feature my-feature)"
  if [ "$(field "$out" storage)" = "local" ] \
    && [ "$(field "$out" branch)" = "main" ] \
    && [ "$(field "$out" on_default_branch)" = "yes" ] \
    && [ "$(field "$out" pending_changes)" -ge 1 ] \
    && [ "$(field "$out" profile)" = "strict" ] \
    && [ "$(field "$out" approval)" = "present" ]; then
    log_pass "$name"
  else
    log_fail "$name ($out)"
  fi
  rm -rf "$dir"
}

test_preflight_linear_approval_unknown() {
  local name="pr-preflight reports approval=unknown in Linear mode and absent without a local marker"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" yes standard
  local out_linear out_local
  out_linear="$(cd "$dir" && bash "$PREFLIGHT")"
  printf '# Config\n\n## Linear Integration\n- Configured: no\n' > "$dir/ship/config.md"
  mkdir -p "$dir/ship/changes/f2"
  out_local="$(cd "$dir" && bash "$PREFLIGHT" --feature f2)"
  if [ "$(field "$out_linear" storage)" = "linear" ] \
    && [ "$(field "$out_linear" approval)" = "unknown" ] \
    && [ "$(field "$out_local" approval)" = "absent" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_preflight_emits_gate_rows() {
  local name="pr-preflight emits one gate_row per phase when the scratch dir exists"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" no standard
  mkdir -p "$dir/.context/ship-run/T1"
  printf '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n|--|--|--|--|--|--|--|--|--|--|\n| dev | #1 | 2026-01-01T00:00:00Z | - | pass | 0 | 0 | 0 | 0 | |\n' \
    > "$dir/.context/ship-run/T1/phase-status.md"
  local out
  out="$(cd "$dir" && bash "$PREFLIGHT" --task T1)"
  if printf '%s' "$out" | grep -q '^gate_row:| dev |'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_finalize_cleans_scratch_and_archives() {
  local name="pr-finalize removes only the task's scratch dir and archives the local feature folder"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" no standard
  mkdir -p "$dir/.context/ship-run/T1" "$dir/.context/ship-run/OTHER" "$dir/ship/changes/my-feature"
  echo x > "$dir/ship/changes/my-feature/report.md"
  local out
  out="$(cd "$dir" && bash "$FINALIZE" T1 --feature my-feature)"
  if [ "$(field "$out" context)" = "cleaned" ] \
    && [ ! -d "$dir/.context/ship-run/T1" ] \
    && [ -d "$dir/.context/ship-run/OTHER" ] \
    && [ ! -d "$dir/ship/changes/my-feature" ] \
    && ls "$dir/ship/changes/archive" | grep -q -- '-my-feature$'; then
    log_pass "$name"
  else
    log_fail "$name ($out)"
  fi
  rm -rf "$dir"
}

test_finalize_keep_context_preserves() {
  local name="pr-finalize --keep-context preserves the scratch dir"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" no standard
  mkdir -p "$dir/.context/ship-run/T1"
  local out
  out="$(cd "$dir" && bash "$FINALIZE" T1 --keep-context)"
  if [ "$(field "$out" context)" = "preserved" ] && [ -d "$dir/.context/ship-run/T1" ] \
    && [ "$(field "$out" archive)" = "none" ]; then
    log_pass "$name"
  else
    log_fail "$name ($out)"
  fi
  rm -rf "$dir"
}

test_finalize_rejects_bad_task_id() {
  local name="pr-finalize rejects a task id with path characters"
  local dir; dir="$(mktemp -d)"
  setup_repo "$dir" no standard
  local status=0
  (cd "$dir" && bash "$FINALIZE" '../evil') >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_preflight_reports_local_state
test_preflight_linear_approval_unknown
test_preflight_emits_gate_rows
test_finalize_cleans_scratch_and_archives
test_finalize_keep_context_preserves
test_finalize_rejects_bad_task_id

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
