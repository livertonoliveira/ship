#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../files-check.sh"

pass_count=0
fail_count=0
log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

issue() {
  local dir="$1" name="$2"
  shift 2
  printf '# %s\n\n## Contexto\n\nx\n\n## Files\n\n' "$name" > "$dir/$name.md"
  printf '%s\n' "$@" >> "$dir/$name.md"
  printf '\n## Deps\n\nnone\n' >> "$dir/$name.md"
}

test_one_verb_one_path_per_entry_passes() {
  local name="entries shaped 'verb path — intent', with a brace group and an anchor line, pass"
  local d; d="$(mktemp -d)"
  issue "$d" TASK-001 '* create src/features/x/lib/a.ts — helper' '* modify src/features/x/hooks/use-{a,b}.ts — imports' '- delete src/features/x/index.ts — barrel' '* Âncora: siga o padrão de src/features/y/index.ts — reexport'
  local out rc=0
  out="$(bash "$CHECK" --issues "$d" 2>&1)" || rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ok files=1 entries=4$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_a_set_described_by_a_count_is_a_violation() {
  local name="'modify ~67 arquivos em src/ — …' is reported as not-a-path with its file and line"
  local d; d="$(mktemp -d)"
  issue "$d" TASK-002 '* modify src/a.ts — ok' '* modify \~67 arquivos em src/ (features/x) — import por caminho; lista via grep'
  local out rc=0
  out="$(bash "$CHECK" --issues "$d" 2>&1)" || rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qE '^.*/TASK-002\.md:[0-9]+: not-a-path: modify ~67 arquivos'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_several_paths_on_one_line_is_a_violation() {
  local name="'modify a.tsx, b.test.tsx — …' is reported as several-paths"
  local d; d="$(mktemp -d)"
  issue "$d" TASK-003 '* modify src/a.tsx, tests/a.test.tsx — mover métrica'
  local out rc=0
  out="$(bash "$CHECK" --issues "$d" 2>&1)" || rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q ': several-paths: modify src/a.tsx, tests/a.test.tsx'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_an_entry_without_a_verb_is_a_violation() {
  local name="an entry with no create/modify/delete verb is reported as no-verb"
  local d; d="$(mktemp -d)"
  issue "$d" TASK-004 '* src/a.ts — sem verbo'
  local out rc=0
  out="$(bash "$CHECK" --issues "$d" 2>&1)" || rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q ': no-verb: src/a.ts'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_a_single_tasks_file_is_checked_too() {
  local name="--tasks <file> checks every ### task's Files section in one file"
  local d; d="$(mktemp -d)"
  printf '## Milestone 1\n\n### TASK-001 — a\n\n## Files\n\n* modify src/a.ts — x\n\n## Deps\n\nnone\n\n### TASK-002 — b\n\n## Files\n\n* modify src/b.ts, src/c.ts — y\n' > "$d/tasks.md"
  local out rc=0
  out="$(bash "$CHECK" --tasks "$d/tasks.md" 2>&1)" || rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'several-paths: modify src/b.ts, src/c.ts'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out')"
  fi
}

test_one_verb_one_path_per_entry_passes
test_a_set_described_by_a_count_is_a_violation
test_several_paths_on_one_line_is_a_violation
test_an_entry_without_a_verb_is_a_violation
test_a_single_tasks_file_is_checked_too

echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
