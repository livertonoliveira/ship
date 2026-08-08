#!/usr/bin/env bash

# The blocking-dependency gate, at both levels: deps-gate.sh's own decisions and
# the pipeline.sh wiring that stops a run before it plans against a base its
# dependency never landed in.
#
# The regression these pin: a task declaring `## Deps` ran plan → develop with
# no check at all, and the planner's own discovery of the same gap reached no
# machine because it was prose in the artifact language.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../deps-gate.sh"
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

make_scratch() {
  local dir="$1" deps="$2"
  mkdir -p "$dir"
  printf '## Files\n- src/a.js\n- src/b.js\n\n## Deps\n%s\n\nTwo modules\n' "$deps" > "$dir/spec.md"
}

# --- deps-gate.sh -------------------------------------------------------------

test_ids_come_from_the_spec_slice() {
  local name="ids reads the per-task spec slice's ## Deps with no task heading"
  local d out; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'ABC-1
ABC-2'
  out="$("$GATE" ids "$d/TASK-9" | tr '\n' ' ')"
  rm -rf "$d"
  [ "$out" = "ABC-1 ABC-2 " ] && log_pass "$name" || log_fail "$name (got: '$out')"
}

test_none_yields_no_gate() {
  local name="a 'none' Deps block yields no ids — an independent task never gates"
  local d out; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'none'
  out="$("$GATE" ids "$d/TASK-9")"
  rm -rf "$d"
  [ -z "$out" ] && log_pass "$name" || log_fail "$name (got: '$out')"
}

test_unknown_state_is_pending() {
  local name="an id with no state line is unresolved, and an unresolvable one stays pending (fail closed)"
  local d unres pend; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'ABC-1'
  unres="$("$GATE" unresolved "$d/TASK-9" | tr '\n' ' ')"
  printf 'ABC-1\tpending\n' > "$d/TASK-9/deps-state.tsv"
  pend="$("$GATE" pending "$d/TASK-9" | tr '\n' ' ')"
  rm -rf "$d"
  if [ "$unres" = "ABC-1 " ] && [ "$pend" = "ABC-1 " ]; then
    log_pass "$name"
  else
    log_fail "$name (unresolved: '$unres', pending: '$pend')"
  fi
}

test_merged_clears_the_gate() {
  local name="a merged dependency is neither unresolved nor pending"
  local d out; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'ABC-1'
  printf 'ABC-1\tmerged\n' > "$d/TASK-9/deps-state.tsv"
  out="$("$GATE" pending "$d/TASK-9")$("$GATE" unresolved "$d/TASK-9")"
  rm -rf "$d"
  [ -z "$out" ] && log_pass "$name" || log_fail "$name (got: '$out')"
}

test_plan_dep_token_is_collected() {
  local name="a planner's 'DEP <id>' line under ## Map Divergences becomes a gated id"
  local d out; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'none'
  printf '## Map Divergences\n- moved a.js -> b.js\n- DEP `ABC-7` — the enum value lands there\n\n## Order\n- M1\n' > "$d/TASK-9/plan.md"
  out="$("$GATE" ids "$d/TASK-9" --plan "$d/TASK-9/plan.md" | tr '\n' ' ')"
  rm -rf "$d"
  [ "$out" = "ABC-7 " ] && log_pass "$name" || log_fail "$name (got: '$out')"
}

test_plan_prose_is_not_a_dep() {
  local name="free prose under ## Map Divergences is not gated — only the DEP token is"
  local d out; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'none'
  printf '## Map Divergences\n- **bloqueante:** a coluna source nao existe em customers\n' > "$d/TASK-9/plan.md"
  out="$("$GATE" ids "$d/TASK-9" --plan "$d/TASK-9/plan.md")"
  rm -rf "$d"
  [ -z "$out" ] && log_pass "$name" || log_fail "$name (got: '$out')"
}

test_self_reference_is_dropped() {
  local name="a task listing its own id as a dep does not deadlock on itself"
  local d out; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'TASK-9
ABC-1'
  out="$("$GATE" ids "$d/TASK-9" | tr '\n' ' ')"
  rm -rf "$d"
  [ "$out" = "ABC-1 " ] && log_pass "$name" || log_fail "$name (got: '$out')"
}

test_ack_is_per_id() {
  local name="ack clears only the ids pending at the time — a later id still gates"
  local d first second; d="$(mktemp -d)"
  make_scratch "$d/TASK-9" 'ABC-1'
  printf 'ABC-1\tpending\n' > "$d/TASK-9/deps-state.tsv"
  "$GATE" ack "$d/TASK-9" >/dev/null
  first="$("$GATE" pending "$d/TASK-9")"
  printf '## Map Divergences\n- DEP ABC-7 — discovered by the planner\n' > "$d/TASK-9/plan.md"
  printf 'ABC-7\tpending\n' >> "$d/TASK-9/deps-state.tsv"
  second="$("$GATE" pending "$d/TASK-9" --plan "$d/TASK-9/plan.md" | tr '\n' ' ')"
  rm -rf "$d"
  if [ -z "$first" ] && [ "$second" = "ABC-7 " ]; then
    log_pass "$name"
  else
    log_fail "$name (first: '$first', second: '$second')"
  fi
}

# --- pipeline.sh wiring -------------------------------------------------------

setup_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    mkdir ship
    printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n## Test Scope\n- unit: enabled\n- integration: disabled\n- e2e: disabled\n\n## Gate Behavior\n- on_fail: ask\n- on_warn: ask\n\n- Test Framework: none\n' > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null
}

next() {
  local dir="$1"
  shift
  (cd "$dir" && bash "$PIPELINE" next "$@")
}

field() {
  printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-
}

stage_task() {
  local dir="$1" deps="$2"
  next "$dir" TASK-1 >/dev/null
  make_scratch "$dir/.context/ship-run/TASK-1" "$deps"
}

test_pipeline_asks_before_planning() {
  local name="a declared dependency is resolved, then gated — before the planner is ever dispatched"
  local dir work ask; dir="$(mktemp -d)"
  setup_repo "$dir"
  stage_task "$dir" 'ABC-1'
  work="$(next "$dir" TASK-1)"
  printf 'ABC-1\tpending\n' > "$dir/.context/ship-run/TASK-1/deps-state.tsv"
  ask="$(next "$dir" TASK-1)"
  local planned="no"
  grep -q '^| plan ' "$dir/.context/ship-run/TASK-1/dispatch-log.md" 2>/dev/null && planned="yes"
  rm -rf "$dir"
  if [ "$(field "$work" state)" = "deps" ] && [ "$(field "$work" action)" = "work" ] \
    && printf '%s' "$work" | grep -q 'deps-state.tsv' \
    && [ "$(field "$ask" state)" = "deps" ] && [ "$(field "$ask" action)" = "ask" ] \
    && printf '%s' "$ask" | grep -q 'ABC-1' \
    && [ "$planned" = "no" ]; then
    log_pass "$name"
  else
    log_fail "$name (work: $(field "$work" action), ask: $(field "$ask" action), planned: $planned)"
  fi
}

test_pipeline_continue_is_not_reasked_on_resume() {
  local name="--answer deps-continue proceeds, and the same question never returns on resume"
  local dir after resume; dir="$(mktemp -d)"
  setup_repo "$dir"
  stage_task "$dir" 'ABC-1'
  next "$dir" TASK-1 >/dev/null
  printf 'ABC-1\tpending\n' > "$dir/.context/ship-run/TASK-1/deps-state.tsv"
  next "$dir" TASK-1 >/dev/null
  after="$(next "$dir" TASK-1 --answer deps-continue)"
  resume="$(next "$dir" TASK-1 --mode resume)"
  rm -rf "$dir"
  if [ "$(field "$after" state)" != "deps" ] && [ "$(field "$resume" state)" != "deps" ]; then
    log_pass "$name"
  else
    log_fail "$name (after: $(field "$after" state), resume: $(field "$resume" state))"
  fi
}

test_pipeline_abort_stops() {
  local name="--answer abort stops the run instead of implementing against a missing base"
  local dir out; dir="$(mktemp -d)"
  setup_repo "$dir"
  stage_task "$dir" 'ABC-1'
  next "$dir" TASK-1 >/dev/null
  printf 'ABC-1\tpending\n' > "$dir/.context/ship-run/TASK-1/deps-state.tsv"
  next "$dir" TASK-1 >/dev/null
  out="$(next "$dir" TASK-1 --answer abort)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "deps" ] && [ "$(field "$out" action)" = "stop" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: $(field "$out" state)/$(field "$out" action))"
  fi
}

test_pipeline_merged_dep_never_gates() {
  local name="a merged dependency lets the run go straight to the planner"
  local dir out; dir="$(mktemp -d)"
  setup_repo "$dir"
  stage_task "$dir" 'ABC-1'
  next "$dir" TASK-1 >/dev/null
  printf 'ABC-1\tmerged\n' > "$dir/.context/ship-run/TASK-1/deps-state.tsv"
  out="$(next "$dir" TASK-1)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "plan" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: $(field "$out" state))"
  fi
}

test_pipeline_gates_planner_discovered_dep() {
  local name="an id the planner discovered gates after validation, before develop"
  local dir out scratch; dir="$(mktemp -d)"
  setup_repo "$dir"
  stage_task "$dir" 'none'
  scratch="$dir/.context/ship-run/TASK-1"
  next "$dir" TASK-1 >/dev/null
  printf '## Modules\n### M1: the module\n- Files: src/a.js, src/b.js\n- Depends on: none\n- Scenarios: none\n- Contract: does the thing\n\n## Test Contract\n\n## Map Divergences\n- DEP ABC-7 — the enum value lands there\n\n## Order\n- M1\n' > "$scratch/plan.md"
  out="$(next "$dir" TASK-1)"
  local dev="no"
  grep -q '^| dev ' "$scratch/dispatch-log.md" 2>/dev/null && dev="yes"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "deps" ] && [ "$dev" = "no" ]; then
    log_pass "$name"
  else
    log_fail "$name (got: $(field "$out" state)/$(field "$out" action), dev dispatched: $dev)"
  fi
}

test_ids_come_from_the_spec_slice
test_none_yields_no_gate
test_unknown_state_is_pending
test_merged_clears_the_gate
test_plan_dep_token_is_collected
test_plan_prose_is_not_a_dep
test_self_reference_is_dropped
test_ack_is_per_id
test_pipeline_asks_before_planning
test_pipeline_continue_is_not_reasked_on_resume
test_pipeline_abort_stops
test_pipeline_merged_dep_never_gates
test_pipeline_gates_planner_discovered_dep

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
