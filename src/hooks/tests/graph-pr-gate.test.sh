#!/usr/bin/env bash

# The graph's only integration gate is the forge: a node is finished when the PR
# it opened is MERGED there, and a dependent is admitted on that and nothing
# else. These tests pin the whole gate — the four PR outcomes, the fact that the
# coordinator's own checkout is never touched, and the escape hatch for a repo
# with no forge at all.
#
# The forge client is stubbed through GH_BIN, so none of this needs a network.

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

new_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    mkdir -p ship
    printf -- '- Test Framework: none\n' > ship/config.md
    git add -A
    git commit -qm init
    git branch -M main
    # A remote is half of what makes a forge gate exist; nothing ever talks to it.
    git remote add origin https://forge.test/acme/repo.git
  )
}

# The stub answers exactly what pr_probe asks for. `--state` picks the verdict;
# the branch `ship/NOPR` gets the no-such-PR answer (non-zero, no output), which
# is what a real client does when nothing was ever opened. A third arg of
# "armed" reports an autoMergeRequest on the PR, the way /ship:pr leaves one
# after arming GitHub's native auto-merge on a landed node.
make_gh() {
  local dir="$1" state="$2" automerge="${3:-}"
  local amr='null'
  [ "$automerge" = "armed" ] && amr='{"enabledAt":"2026-07-31T00:00:00Z"}'
  cat > "$dir/fake-gh" <<EOF
#!/usr/bin/env bash
branch="\$3"
case "\$branch" in
  ship/NOPR) exit 1 ;;
esac
printf '{"number":7,"state":"$state","url":"https://forge.test/acme/repo/pull/7","autoMergeRequest":$amr}\n'
EOF
  chmod +x "$dir/fake-gh"
}

init_graph() {
  local dir="$1"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-001", "title": "Base", "deps": [], "files": ["src/good.ts"] },
  { "id": "TASK-002", "title": "Depende", "deps": ["TASK-001"], "files": ["src/other.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
  )
}

landed_node() {
  local dir="$1" task="$2" file="$3"
  (
    cd "$dir"
    git worktree add -q "wt-$task" -b "ship/$task" main
    mkdir -p "wt-$task/$(dirname "$file")"
    printf 'export const x = 1\n' > "wt-$task/$file"
    git -C "wt-$task" add -A
    git -C "wt-$task" commit -qm "feat: $task"
    bash "$GRAPH" claim "$task" --worktree "wt-$task" --branch "ship/$task" >/dev/null
    bash "$GRAPH" land "$task" >/dev/null
  )
}

test_a_merged_pr_completes_the_node() {
  local name="a landed node whose PR is MERGED on the forge becomes merged"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" MERGED
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^merged=TASK-001$' \
    && printf '%s' "$json" | grep -q '"status": "merged"' \
    && printf '%s' "$json" | grep -q '"last_merged": "TASK-001"' \
    && printf '%s' "$json" | grep -q '"pr_url": "https://forge.test/acme/repo/pull/7"'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_an_open_pr_keeps_the_node_landed() {
  local name="an OPEN PR leaves the node landed and reports it as awaiting merge"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" OPEN
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^awaiting_merge=TASK-001$' \
    && printf '%s' "$json" | grep -q '"status": "landed"'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_a_closed_pr_fails_the_node() {
  local name="a PR closed without merging fails the node instead of hanging the graph"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" CLOSED
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^pr_closed=TASK-001$' \
    && printf '%s' "$json" | grep -q '"status": "failed"'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_a_missing_pr_is_surfaced_not_assumed() {
  local name="a landed node with no PR on the forge is reported, never taken as merged"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  (
    cd "$dir"
    git worktree add -q wt-nopr -b ship/NOPR main
    printf 'x\n' > wt-nopr/g.txt
    git -C wt-nopr add -A
    git -C wt-nopr commit -qm "feat: nopr"
    bash "$GRAPH" claim TASK-001 --worktree wt-nopr --branch ship/NOPR >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
  )
  make_gh "$dir" MERGED
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^pr_missing=TASK-001$' \
    && printf '%s' "$json" | grep -q '"status": "landed"'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_the_coordinator_checkout_is_never_touched() {
  local name="polling a merged PR merges nothing locally — the coordinator's HEAD stands still"
  local dir before after present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" MERGED
  before="$(git -C "$dir" rev-parse HEAD)"
  (cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll >/dev/null)
  after="$(git -C "$dir" rev-parse HEAD)"
  [ -f "$dir/src/good.ts" ] && present=1
  rm -rf "$dir"

  if [ "$before" = "$after" ] && [ "$present" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (head_moved=$([ "$before" = "$after" ] && echo no || echo yes) file_in_base=$present)"
  fi
}

test_a_dependent_waits_for_the_real_merge() {
  local name="a dependent is admitted only once its dependency's PR is merged, not when it lands"
  local dir while_open after_merge
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" OPEN
  (cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll >/dev/null)
  while_open="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" next)"
  make_gh "$dir" MERGED
  (cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll >/dev/null)
  after_merge="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$while_open" state)" = "landed" ] \
    && [ -z "$(field "$while_open" frontier)" ] \
    && [ "$(field "$after_merge" frontier)" = "TASK-002" ]; then
    log_pass "$name"
  else
    log_fail "$name (open: state='$(field "$while_open" state)' frontier='$(field "$while_open" frontier)'; merged: frontier='$(field "$after_merge" frontier)')"
  fi
}

test_next_hands_the_open_prs_to_the_user() {
  local name="with nothing left to dispatch, next presents the open PRs and its exits"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" OPEN
  (cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll >/dev/null)
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "landed" ] \
    && [ "$(field "$out" action)" = "ask" ] \
    && printf '%s' "$out" | grep -q 'https://forge.test/acme/repo/pull/7' \
    && printf '%s' "$out" | grep -q 'graph.sh" poll' \
    && printf '%s' "$out" | grep -q 'graph.sh" fail'; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_an_armed_pr_waits_instead_of_asking() {
  local name="an OPEN PR with auto-merge armed reports wait, not ask — nobody needs to merge it by hand"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" OPEN armed
  (cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll >/dev/null)
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "landed" ] \
    && [ "$(field "$out" action)" = "wait" ] \
    && printf '%s' "$out" | grep -q 'graph.sh" poll'; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_an_unarmed_pr_still_asks() {
  local name="an OPEN PR with no auto-merge armed still needs a human — action stays ask"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  make_gh "$dir" OPEN
  (cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll >/dev/null)
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "landed" ] && [ "$(field "$out" action)" = "ask" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_no_forge_does_not_deadlock_the_run() {
  local name="a repo with no forge settles landed nodes instead of waiting on a signal that cannot come"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  (cd "$dir" && git remote remove origin)
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  out="$(cd "$dir" && bash "$GRAPH" poll)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^merged=TASK-001$' \
    && printf '%s' "$json" | grep -q '"pr_state": "no-forge"'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_next_settles_a_forgeless_node_itself() {
  local name="next does not park on a landed node that no forge will ever report"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  (cd "$dir" && git remote remove origin)
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" frontier)" = "TASK-002" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' frontier='$(field "$out" frontier)')"
  fi
}

test_complete_is_the_manual_override() {
  local name="complete moves a landed node to merged for a merge the forge cannot report"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 src/good.ts
  out="$(cd "$dir" && bash "$GRAPH" complete TASK-001)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if [ "$(field "$out" completed)" = "TASK-001" ] \
    && printf '%s' "$json" | grep -q '"status": "merged"'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_complete_refuses_a_node_that_has_not_landed() {
  local name="complete refuses a node that is still in flight"
  local dir rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  (
    cd "$dir"
    git worktree add -q wt-TASK-001 -b ship/TASK-001 main
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" complete TASK-001 >/dev/null 2>&1
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (complete accepted an in-flight node)"
  fi
}

test_the_graph_has_no_merge_verb_left() {
  local name="graph.sh exposes no merge subcommand — merging is the forge's job"
  local dir rc=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  (cd "$dir" && bash "$GRAPH" merge TASK-001 >/dev/null 2>&1) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && ! grep -q '^cmd_merge()' "$GRAPH"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — graph.sh still answers 'merge')"
  fi
}

test_a_merged_pr_completes_the_node
test_an_open_pr_keeps_the_node_landed
test_a_closed_pr_fails_the_node
test_a_missing_pr_is_surfaced_not_assumed
test_the_coordinator_checkout_is_never_touched
test_a_dependent_waits_for_the_real_merge
test_next_hands_the_open_prs_to_the_user
test_an_armed_pr_waits_instead_of_asking
test_an_unarmed_pr_still_asks
test_no_forge_does_not_deadlock_the_run
test_next_settles_a_forgeless_node_itself
test_complete_is_the_manual_override
test_complete_refuses_a_node_that_has_not_landed
test_the_graph_has_no_merge_verb_left

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
