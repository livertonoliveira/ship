#!/usr/bin/env bash

# Pins the `## Deps` contract emitted by /ship:spec before the work graph
# consumes it. The whole point of the block is that it is machine-parseable —
# so the test asserts the extraction over a fixture, not just that the words
# appear in the SKILL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPEC_SKILL="$REPO_ROOT/src/skills/spec/SKILL.md"

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

# The canonical extraction: every bare line under `## Deps`, until the next
# heading, minus the `none` sentinel. graph.sh and /ship:graph must agree with it.
extract_deps() {
  local file="$1" task="$2"
  awk -v task="$task" '
    $0 ~ "^###+[[:space:]]+" task "([[:space:]]|$)" { intask = 1; indeps = 0; next }
    intask && /^###+[[:space:]]/ { intask = 0; indeps = 0 }
    intask && /^##[[:space:]]+Deps[[:space:]]*$/ { indeps = 1; next }
    intask && /^#/ { indeps = 0 }
    indeps {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/`/, "")
      if ($0 == "" || tolower($0) == "none") next
      print
    }
  ' "$file"
}

make_fixture() {
  cat > "$1" <<'EOF'
# Tasks

## Milestone 1

### TASK-001 — Schema de pedidos

## Files
create src/db/schema.ts — tabela de pedidos

## Deps
none

### TASK-002 — Endpoint de checkout

## Files
modify src/api/routes.ts — registrar rota

## Deps
TASK-001

### TASK-003 — Tela de checkout

## Files
create src/web/checkout.tsx — formulário

## Deps
TASK-001
TASK-002

### TASK-004 — Legado sem bloco

## Files
modify src/legacy.ts — ajuste

Notes: depende da TASK-001
EOF
}

test_skill_documents_deps_block() {
  local name="spec SKILL.md emits a ## Deps block instead of free-text notes"
  if grep -q '`## Deps`' "$SPEC_SKILL"; then
    log_pass "$name"
  else
    log_fail "$name (no \`## Deps\` contract found in $SPEC_SKILL)"
  fi
}

test_skill_dropped_notes_deps() {
  local name="the old unstructured 'Notes (deps)' task-template slot is gone"
  if grep -q 'Notes (deps)' "$SPEC_SKILL"; then
    log_fail "$name (still present)"
  else
    log_pass "$name"
  fi
}

test_skill_requires_blocked_by_in_linear() {
  local name="Linear mode also sets the native blocked-by relation"
  if grep -qi 'blocked by' "$SPEC_SKILL"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_single_dep_parses() {
  local name="a task with one dep yields exactly that ID"
  local f out
  f="$(mktemp)"
  make_fixture "$f"
  out="$(extract_deps "$f" TASK-002 | tr '\n' ' ')"
  rm -f "$f"
  if [ "$out" = "TASK-001 " ]; then
    log_pass "$name"
  else
    log_fail "$name (got: '$out')"
  fi
}

test_multiple_deps_parse_in_order() {
  local name="a task with two deps yields both, in file order"
  local f out
  f="$(mktemp)"
  make_fixture "$f"
  out="$(extract_deps "$f" TASK-003 | tr '\n' ' ')"
  rm -f "$f"
  if [ "$out" = "TASK-001 TASK-002 " ]; then
    log_pass "$name"
  else
    log_fail "$name (got: '$out')"
  fi
}

test_none_sentinel_yields_empty() {
  local name="the 'none' sentinel yields no deps (an independent root node)"
  local f out
  f="$(mktemp)"
  make_fixture "$f"
  out="$(extract_deps "$f" TASK-001)"
  rm -f "$f"
  if [ -z "$out" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: '$out')"
  fi
}

test_free_text_notes_are_not_parseable() {
  local name="legacy free-text 'Notes: depende da TASK-001' yields nothing — the reason the block exists"
  local f out
  f="$(mktemp)"
  make_fixture "$f"
  out="$(extract_deps "$f" TASK-004)"
  rm -f "$f"
  if [ -z "$out" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: '$out')"
  fi
}

test_deps_do_not_leak_across_tasks() {
  local name="a task's Deps block never absorbs the next task's block"
  local f out
  f="$(mktemp)"
  make_fixture "$f"
  out="$(extract_deps "$f" TASK-002 | wc -l | tr -d ' ')"
  rm -f "$f"
  if [ "$out" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (got $out lines, expected 1)"
  fi
}

test_skill_documents_deps_block
test_skill_dropped_notes_deps
test_skill_requires_blocked_by_in_linear
test_single_dep_parses
test_multiple_deps_parse_in_order
test_none_sentinel_yields_empty
test_free_text_notes_are_not_parseable
test_deps_do_not_leak_across_tasks

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
