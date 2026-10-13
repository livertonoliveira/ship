#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../task-merge.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

node() {
  # node <id> <deps,csv> <files,csv> [lines]
  local deps files
  deps="$(printf '%s' "$2" | awk -F, '{ for (i = 1; i <= NF; i++) if ($i != "") printf "%s\"%s\"", (i > 1 ? ", " : ""), $i }')"
  files="$(printf '%s' "$3" | awk -F, '{ for (i = 1; i <= NF; i++) if ($i != "") printf "%s\"%s\"", (i > 1 ? ", " : ""), $i }')"
  printf '  { "id": "%s", "repo": "r", "title": "t", "deps": [%s], "files": [%s]%s }' "$1" "$deps" "$files" "${4:+, \"lines\": $4}"
}

graph() {
  local first=1 n
  printf '[\n'
  for n in "$@"; do
    [ "$first" -eq 1 ] || printf ',\n'
    printf '%s' "$n"
    first=0
  done
  printf '\n]\n'
}

run() {
  local f; f="$(mktemp)"
  cat > "$f"
  local rc=0
  OUT="$(bash "$MERGE" --from "$f" "${@}" 2>&1)" || rc=$?
  rm -f "$f"
  return "$rc"
}

# Measured on the 27-node api-astros graph: TASK-006/007/008 each declared
# jpl.provider.ts and its spec — three PRs over one file, three nodes billed.
test_tasks_on_the_same_files_are_one_task() {
  local name="tasks whose files mostly coincide are proposed as one, transitively"
  local rc=0
  run < <(graph "$(node A '' 'src/p.ts,test/p.spec.ts')" \
        "$(node B 'A' 'src/p.ts,test/p.spec.ts')" \
        "$(node C 'B' 'src/p.ts,src/q.ts,test/p.spec.ts')") || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '^merge A+B+C reason=overlap files=3' \
    && printf '%s' "$OUT" | grep -q '^nodes=3 proposals=1 after=1$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$OUT)"
  fi
}

test_one_hub_file_does_not_glue_unrelated_tasks() {
  local name="one shared registry file among four is below the overlap fraction — no proposal, exit 1"
  local rc=0
  run < <(graph "$(node A '' 'src/index.ts,src/a.ts,src/a2.ts,test/a.spec.ts')" \
        "$(node B '' 'src/index.ts,src/b.ts,src/b2.ts,test/b.spec.ts')") || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q '^nodes=2 proposals=0 after=2$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$OUT)"
  fi
}

test_a_straight_chain_is_one_task() {
  local name="B depending only on A, A feeding only B, is one task (chain)"
  local rc=0
  run < <(graph "$(node A '' 'src/a.ts,test/a.spec.ts')" \
        "$(node B 'A' 'src/b.ts,test/b.spec.ts')" \
        "$(node C '' 'src/c.ts')") || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '^merge A+B reason=chain files=4 delays=0$' \
    && printf '%s' "$OUT" | grep -q '^nodes=3 proposals=1 after=2$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$OUT)"
  fi
}

test_a_chain_with_a_side_dependent_is_not_merged() {
  local name="A feeding both B and C is not a straight chain — nothing merges"
  local rc=0
  run < <(graph "$(node A '' 'src/a.ts')" \
        "$(node B 'A' 'src/b.ts')" \
        "$(node C 'A' 'src/c.ts')") || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'proposals=0'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$OUT)"
  fi
}

test_merge_that_would_cycle_is_refused() {
  local name="A and C overlapping with B in between (A→B→C, B not mergeable with either) would be a cycle — refused"
  local rc=0
  run < <(graph "$(node A '' 'src/x.ts,test/x.spec.ts')" \
        "$(node E '' 'src/e.ts')" \
        "$(node B 'A,E' 'src/b.ts,src/b2.ts,src/b3.ts')" \
        "$(node C 'B' 'src/x.ts,test/x.spec.ts')" \
        "$(node D 'B' 'src/d.ts')") || rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'proposals=0'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$OUT)"
  fi
}

test_reviewability_caps_hold() {
  local name="a merge past --max-files or --max-lines is refused, so the PR stays reviewable"
  local rc=0
  run --max-files 8 < <(graph "$(node A '' 'src/p.ts,a1,a2,a3,a4' 300)" \
        "$(node B 'A' 'src/p.ts,b1,b2,b3,b4' 300)") || rc=$?
  local rc2=0
  run --max-lines 600 < <(graph "$(node A '' 'src/p.ts,test/p.spec.ts' 350)" \
        "$(node B 'A' 'src/p.ts,test/p.spec.ts' 300)") || rc2=$?
  local rc3=0
  run --max-lines 600 < <(graph "$(node A '' 'src/p.ts,test/p.spec.ts' 200)" \
        "$(node B 'A' 'src/p.ts,test/p.spec.ts' 300)") || rc3=$?
  if [ "$rc" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 0 ] \
    && printf '%s' "$OUT" | grep -q '^merge A+B reason=overlap files=2 lines=500 delays=0$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc/$rc2/$rc3 out=$OUT)"
  fi
}

test_delays_counts_who_would_wait_on_work_they_did_not_need() {
  local name="delays= counts the outside tasks that depended on one member but not on all"
  local rc=0
  run < <(graph "$(node A '' 'src/p.ts,test/p.spec.ts')" \
        "$(node B 'A' 'src/p.ts,test/p.spec.ts')" \
        "$(node D 'A' 'src/d.ts')") || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '^merge A+B reason=overlap files=2 delays=1$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$OUT)"
  fi
}

test_different_repos_never_merge() {
  local name="tasks in different repos never merge, whatever they share"
  local f; f="$(mktemp)"
  printf '[\n  { "id": "A", "repo": "api", "title": "t", "deps": [], "files": ["shared/p.ts"] },\n  { "id": "B", "repo": "web", "title": "t", "deps": [], "files": ["shared/p.ts"] }\n]\n' > "$f"
  local rc=0 out
  out="$(bash "$MERGE" --from "$f" 2>&1)" || rc=$?
  rm -f "$f"
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'proposals=0'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
}

test_bad_input_exits_2() {
  local name="a missing file or an empty node list exits 2"
  local rc=0 rc2=0
  bash "$MERGE" --from /nonexistent/nodes.json >/dev/null 2>&1 || rc=$?
  run < <(printf '[]\n') >/dev/null 2>&1 || rc2=$?
  if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc rc2=$rc2)"
  fi
}

test_tasks_md_is_read_through_the_graph_parser() {
  local name="--tasks reads a spec draft through graph.sh nodes, so both inputs share one Files/Deps parser"
  local d; d="$(mktemp -d)"
  cat > "$d/tasks.md" <<'EOT'
### TASK-001 — Provider

## Files
create src/p.ts — provider
create test/p.spec.ts — spec

## Deps
none

### TASK-002 — Provider: Moon

## Files
modify src/p.ts — moon
modify test/p.spec.ts — spec

## Deps
TASK-001
EOT
  local rc=0 out
  out="$(bash "$MERGE" --tasks "$d/tasks.md" 2>&1)" || rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^merge TASK-001+TASK-002 reason=overlap files=2 delays=0$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
}

test_tasks_on_the_same_files_are_one_task
test_tasks_md_is_read_through_the_graph_parser
test_one_hub_file_does_not_glue_unrelated_tasks
test_a_straight_chain_is_one_task
test_a_chain_with_a_side_dependent_is_not_merged
test_merge_that_would_cycle_is_refused
test_reviewability_caps_hold
test_delays_counts_who_would_wait_on_work_they_did_not_need
test_different_repos_never_merge
test_bad_input_exits_2

echo ""
echo "${pass_count} passed, ${fail_count} failed"
[ "$fail_count" -eq 0 ]
