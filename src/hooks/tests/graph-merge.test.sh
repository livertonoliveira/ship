#!/usr/bin/env bash

# The merge node is the verification a single task's pipeline cannot do: two
# nodes green in isolation can be red together. These tests cover the green
# path, the red path with its capped fix loop, and the property the whole design
# leans on — that a scratch dir with no generated-tests.md makes test-exec.sh
# run the ENTIRE suite rather than the last task's slice.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"

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

# A repo whose "suite" is a script that fails whenever src/bad.ts is present —
# the smallest honest stand-in for "these two changes are fine apart and broken
# together". It also records the argv it was called with, which is how the
# whole-suite assertion below is made.
new_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    cat > integration-check.sh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > .suite-argv.txt
if [ -f src/bad.ts ]; then
  echo "FAIL src/bad.ts"
  exit 1
fi
echo "ok"
EOF
    chmod +x integration-check.sh
    mkdir -p ship
    printf -- '- Test Framework: bash ./integration-check.sh\n' > ship/config.md
    git add -A
    git commit -qm init
    git branch -M main
  )
}

add_node_branch() {
  local dir="$1" task="$2" file="$3"
  (
    cd "$dir"
    git worktree add -q "wt-$task" -b "ship/$task" main
    mkdir -p "wt-$task/$(dirname "$file")"
    printf 'export const x = 1\n' > "wt-$task/$file"
    git -C "wt-$task" add -A
    git -C "wt-$task" commit -qm "feat: $task"
  )
}

init_two_node_graph() {
  local dir="$1"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-001", "title": "Boa", "deps": [], "files": ["src/good.ts"] },
  { "id": "TASK-002", "title": "Quebra junto", "deps": [], "files": ["src/bad.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
  )
}

test_green_merge_completes_the_node() {
  local name="a merge whose suite passes marks the node done and integration green"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-001 src/good.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" merge TASK-001)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if [ "$(field "$out" result)" = "green" ] \
    && printf '%s' "$json" | grep -q '"status": "done"' \
    && printf '%s' "$json" | grep -q '"last_merged": "TASK-001"'; then
    log_pass "$name"
  else
    log_fail "$name (result='$(field "$out" result)')"
  fi
}

test_green_merge_actually_lands_on_the_base() {
  local name="a green merge really brings the branch's commit into the base checkout"
  local dir present
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-001 src/good.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
    bash "$GRAPH" merge TASK-001 >/dev/null
  )
  present=0
  [ -f "$dir/src/good.ts" ] && present=1
  rm -rf "$dir"

  if [ "$present" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (src/good.ts is not in the base checkout after the merge)"
  fi
}

test_merge_runs_the_whole_suite_not_a_slice() {
  local name="the synthetic scratch has no generated-tests.md, so the runner gets no file scope"
  local dir argv scratch_has_manifest=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-001 src/good.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
    bash "$GRAPH" merge TASK-001 >/dev/null
  )
  argv="$(cat "$dir/.suite-argv.txt" 2>/dev/null || echo MISSING)"
  [ -f "$dir/.context/ship-graph/f/merge/TASK-001/generated-tests.md" ] && scratch_has_manifest=1
  rm -rf "$dir"

  if [ "$argv" = "" ] && [ "$scratch_has_manifest" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (suite argv='$argv', manifest_present=$scratch_has_manifest)"
  fi
}

test_red_merge_reports_red_and_keeps_the_node_merging() {
  local name="a merge whose suite fails reports red and leaves the node in merging"
  local dir out rc=0 json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-002 src/bad.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-002 --worktree wt-TASK-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" land TASK-002 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" merge TASK-002)" || rc=$?
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && [ "$(field "$out" result)" = "red" ] \
    && printf '%s' "$json" | grep -q '"status": "merging"' \
    && printf '%s' "$json" | grep -q '"status": "red"'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc result='$(field "$out" result)')"
  fi
}

test_red_merge_writes_failures_for_the_fix_agent() {
  local name="a red merge leaves test-failures.md for the fix agent to read"
  local dir failures=""
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-002 src/bad.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-002 --worktree wt-TASK-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" land TASK-002 >/dev/null
    bash "$GRAPH" merge TASK-002 >/dev/null 2>&1 || true
  )
  [ -s "$dir/.context/ship-graph/f/merge/TASK-002/test-failures.md" ] && failures=ok
  rm -rf "$dir"

  if [ "$failures" = "ok" ]; then
    log_pass "$name"
  else
    log_fail "$name (no test-failures.md in the merge scratch)"
  fi
}

test_merge_fix_loop_is_capped_at_two_rounds() {
  local name="the merge fix loop dispatches at most twice, then asks"
  local dir first second third
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-002 src/bad.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-002 --worktree wt-TASK-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" land TASK-002 >/dev/null
    bash "$GRAPH" merge TASK-002 >/dev/null 2>&1 || true
  )
  first="$(cd "$dir" && bash "$GRAPH" next)"
  second="$(cd "$dir" && bash "$GRAPH" next)"
  third="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$first" state)" = "merge-fix" ] \
    && [ "$(field "$second" state)" = "merge-fix" ] \
    && [ "$(field "$third" action)" = "ask" ]; then
    log_pass "$name"
  else
    log_fail "$name (states: $(field "$first" state) / $(field "$second" state) / $(field "$third" state))"
  fi
}

test_re_merge_after_a_fix_does_not_merge_twice() {
  local name="re-running merge after a fix re-verifies without a second merge commit"
  local dir out before after
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-002 src/bad.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-002 --worktree wt-TASK-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" land TASK-002 >/dev/null
    bash "$GRAPH" merge TASK-002 >/dev/null 2>&1 || true
  )
  before="$(git -C "$dir" rev-list --count HEAD)"
  # The "fix": remove what made the integrated tree red.
  (
    cd "$dir"
    rm -f src/bad.ts
    git add -- src
    git commit -qm "fix: drop bad"
  )
  out="$(cd "$dir" && bash "$GRAPH" merge TASK-002)"
  after="$(git -C "$dir" rev-list --count HEAD)"
  rm -rf "$dir"

  # One new commit — the fix — and no second merge of the same branch.
  if [ "$(field "$out" result)" = "green" ] && [ "$after" -eq "$((before + 1))" ]; then
    log_pass "$name"
  else
    log_fail "$name (result='$(field "$out" result)' commits $before → $after)"
  fi
}

test_merge_is_serialized() {
  local name="with two landed nodes, next asks to merge exactly one"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-001 src/good.ts
  add_node_branch "$dir" TASK-002 src/other.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" claim TASK-002 --worktree wt-TASK-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
    bash "$GRAPH" land TASK-002 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "merge" ] \
    && [ "$(printf '%s' "$out" | grep -c 'graph.sh" merge ')" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)')"
  fi
}

test_merge_rejects_a_node_that_has_not_landed() {
  local name="merge refuses a node that is still in flight"
  local dir rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_two_node_graph "$dir"
  add_node_branch "$dir" TASK-001 src/good.ts
  (
    cd "$dir"
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" merge TASK-001 >/dev/null 2>&1
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (merge accepted an in-flight node)"
  fi
}

test_green_merge_completes_the_node
test_green_merge_actually_lands_on_the_base
test_merge_runs_the_whole_suite_not_a_slice
test_red_merge_reports_red_and_keeps_the_node_merging
test_red_merge_writes_failures_for_the_fix_agent
test_merge_fix_loop_is_capped_at_two_rounds
test_re_merge_after_a_fix_does_not_merge_twice
test_merge_is_serialized
test_merge_rejects_a_node_that_has_not_landed

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
