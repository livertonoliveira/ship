#!/usr/bin/env bash

# One issue, one workspace, one PR. Three seams carry that, and each is easy to
# break silently:
#
#   * claim writes the pr-mode marker (with the graph's base, never main) into
#     the node's scratch dir — the only place the node's own pipeline can learn
#     it is running inside a graph;
#   * pipeline.sh turns that marker into a node-pr step BEFORE homolog, because
#     homolog-approved.txt is what the graph polls to land and seal;
#   * a green merge publishes the base, which is what closes the node's PR as
#     merged — and a failed push must never roll a green node back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"
PR_PREFLIGHT="$SCRIPT_DIR/../pr-preflight.sh"
PR_FINALIZE="$SCRIPT_DIR/../pr-finalize.sh"

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
    printf 'ok\n' > README.md
    mkdir -p ship
    printf -- '- Test Framework: bash -c true\n' > ship/config.md
    git add -A
    git commit -qm init
    git branch -M main
    git checkout -q -b feat/base
  )
}

init_graph() {
  local dir="$1"
  shift
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[ { "id": "TASK-001", "title": "Um no", "deps": [], "files": ["src/a.ts"] } ]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch feat/base "$@" >/dev/null
  )
}

claimed_workspace() {
  local dir="$1"
  (
    cd "$dir"
    git worktree add -q wt -b ship/TASK-001 feat/base
    bash "$GRAPH" claim TASK-001 --worktree wt --branch ship/TASK-001
  )
}

test_claim_writes_the_pr_marker_with_the_graph_base() {
  local name="claim writes pr-mode.txt carrying the graph's base branch, not main"
  local dir out marker
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  out="$(claimed_workspace "$dir")"
  marker="$(cat "$dir/wt/.context/ship-run/TASK-001/pr-mode.txt" 2>/dev/null || echo MISSING)"
  rm -rf "$dir"

  if [ "$(field "$out" node_pr)" = "on" ] \
    && printf '%s' "$marker" | grep -q '^mode=graph$' \
    && printf '%s' "$marker" | grep -q '^base=feat/base$'; then
    log_pass "$name"
  else
    log_fail "$name (node_pr='$(field "$out" node_pr)' marker='$marker')"
  fi
}

test_node_pr_off_writes_no_marker() {
  local name="--node-pr off leaves no marker, so the node's pipeline opens nothing"
  local dir out present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir" --node-pr off
  out="$(claimed_workspace "$dir")"
  [ -f "$dir/wt/.context/ship-run/TASK-001/pr-mode.txt" ] && present=1
  rm -rf "$dir"

  if [ "$present" -eq 0 ] && [ "$(field "$out" node_pr)" = "off" ]; then
    log_pass "$name"
  else
    log_fail "$name (present=$present node_pr='$(field "$out" node_pr)')"
  fi
}

test_set_flips_node_pr_on_a_live_graph() {
  local name="set --node-pr off takes effect on the next claim without a re-init"
  local dir present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  (
    cd "$dir"
    bash "$GRAPH" set --node-pr off >/dev/null
  )
  claimed_workspace "$dir" >/dev/null
  [ -f "$dir/wt/.context/ship-run/TASK-001/pr-mode.txt" ] && present=1
  rm -rf "$dir"

  if [ "$present" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (the marker survived --node-pr off)"
  fi
}

# A pipeline repo reduced to the one transition under test: dev and test
# disabled means `next` walks straight to the end, so what it emits there is
# exactly the node-pr-vs-homolog decision and nothing else.
pipeline_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    mkdir ship
    printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n## Test Scope\n- unit: disabled\n- integration: disabled\n- e2e: disabled\n\n## Pipeline Phases\n- dev: disabled\n- test: disabled\n\n## Gate Behavior\n- on_fail: ask\n- on_warn: ask\n\n- Test Framework: none\n' > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null
}

# The ordering property the whole design rests on: if the node-pr step came
# after homolog, the graph would have already sealed the workspace into a single
# blob commit and the PR's atomic commits would never exist.
test_pipeline_emits_the_node_pr_step_before_homolog() {
  local name="next emits node-pr with the graph base, before writing homolog-approved.txt"
  local dir out scratch homolog_written=0
  dir="$(mktemp -d)"
  pipeline_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$dir/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=feat/base\n' > "$scratch/pr-mode.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  [ -f "$scratch/homolog-approved.txt" ] && homolog_written=1
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^state=node-pr$' \
    && printf '%s' "$out" | grep -q 'pr_base=feat/base' \
    && [ "$homolog_written" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' homolog_written=$homolog_written)"
  fi
}

test_pipeline_moves_past_node_pr_once_the_pr_exists() {
  local name="with pr-created.txt on disk the step is not re-emitted and the run finishes"
  local dir out scratch
  dir="$(mktemp -d)"
  pipeline_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$dir/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=feat/base\n' > "$scratch/pr-mode.txt"
  printf 'defer\n' > "$scratch/homolog-mode.txt"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  printf 'created\n' > "$scratch/pr-created.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "done" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)')"
  fi
}

test_no_marker_means_no_node_pr_step() {
  local name="a plain /ship:run (no marker) never sees a node-pr step"
  local dir out scratch
  dir="$(mktemp -d)"
  pipeline_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$dir/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "homolog" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)')"
  fi
}

test_pr_created_marker_retires_the_step() {
  local name="pr-finalize --keep-context writes pr-created.txt so the step is not re-emitted"
  local dir out marker=0
  dir="$(mktemp -d)"
  mkdir -p "$dir/.context/ship-run/TASK-001"
  out="$(cd "$dir" && bash "$PR_FINALIZE" TASK-001 --keep-context)"
  [ -f "$dir/.context/ship-run/TASK-001/pr-created.txt" ] && marker=1
  rm -rf "$dir"

  if [ "$marker" -eq 1 ] && [ "$(field "$out" context)" = "preserved" ]; then
    log_pass "$name"
  else
    log_fail "$name (marker=$marker context='$(field "$out" context)')"
  fi
}

test_preflight_reports_the_graph_base_and_keep_context() {
  local name="pr-preflight reads the marker and reports pr_base + keep_context=yes"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  mkdir -p "$dir/.context/ship-run/TASK-001"
  printf 'mode=graph\nbase=feat/base\n' > "$dir/.context/ship-run/TASK-001/pr-mode.txt"
  out="$(cd "$dir" && bash "$PR_PREFLIGHT" --task TASK-001)"
  rm -rf "$dir"

  if [ "$(field "$out" pr_base)" = "feat/base" ] && [ "$(field "$out" keep_context)" = "yes" ]; then
    log_pass "$name"
  else
    log_fail "$name (pr_base='$(field "$out" pr_base)' keep_context='$(field "$out" keep_context)')"
  fi
}

test_preflight_outside_a_graph_keeps_the_default_base() {
  local name="with no marker the preflight reports keep_context=no and a default base"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  mkdir -p "$dir/.context/ship-run/TASK-001"
  out="$(cd "$dir" && bash "$PR_PREFLIGHT" --task TASK-001)"
  rm -rf "$dir"

  if [ "$(field "$out" keep_context)" = "no" ] && [ "$(field "$out" pr_base)" = "main" ]; then
    log_pass "$name"
  else
    log_fail "$name (pr_base='$(field "$out" pr_base)' keep_context='$(field "$out" keep_context)')"
  fi
}

test_preflight_resolves_a_remote_not_named_origin() {
  local name="the preflight reports the repo's actual remote, whatever it is called"
  local dir remote out
  dir="$(mktemp -d)"
  remote="$(mktemp -d)"
  git init -q --bare "$remote/forja.git"
  new_repo "$dir"
  (cd "$dir" && git remote add forja "$remote/forja.git")
  out="$(cd "$dir" && bash "$PR_PREFLIGHT" --task TASK-001)"
  rm -rf "$dir" "$remote"

  if [ "$(field "$out" remote)" = "forja" ]; then
    log_pass "$name"
  else
    log_fail "$name (remote='$(field "$out" remote)')"
  fi
}

# The merge node is the only thing that may merge, so publishing is what turns
# its verdict into a closed PR upstream.
test_green_merge_publishes_the_base() {
  local name="a green merge pushes the base, which is what closes the node's PR as merged"
  local dir remote out pushed
  dir="$(mktemp -d)"
  remote="$(mktemp -d)"
  git init -q --bare "$remote/origin.git"
  new_repo "$dir"
  init_graph "$dir"
  (
    cd "$dir"
    git remote add origin "$remote/origin.git"
    git push -q -u origin feat/base
    git worktree add -q wt -b ship/TASK-001 feat/base
    mkdir -p wt/src
    printf 'export const a = 1\n' > wt/src/a.ts
    git -C wt add -A
    git -C wt commit -qm "feat: TASK-001"
    bash "$GRAPH" claim TASK-001 --worktree wt --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" merge TASK-001)"
  pushed="$(git -C "$remote/origin.git" log --oneline feat/base 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$dir" "$remote"

  if [ "$(field "$out" result)" = "green" ] \
    && [ "$(field "$out" published)" = "yes" ] \
    && [ "$pushed" -ge 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (published='$(field "$out" published)' commits_on_remote=$pushed)"
  fi
}

test_green_merge_publishes_to_a_remote_not_named_origin() {
  local name="a repo whose only remote is not called origin still gets its base published"
  local dir remote out pushed
  dir="$(mktemp -d)"
  remote="$(mktemp -d)"
  git init -q --bare "$remote/forja.git"
  new_repo "$dir"
  init_graph "$dir"
  (
    cd "$dir"
    git remote add forja "$remote/forja.git"
    git push -q -u forja feat/base
    git worktree add -q wt -b ship/TASK-001 feat/base
    mkdir -p wt/src
    printf 'export const a = 1\n' > wt/src/a.ts
    git -C wt add -A
    git -C wt commit -qm "feat: TASK-001"
    bash "$GRAPH" claim TASK-001 --worktree wt --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" merge TASK-001)"
  pushed="$(git -C "$remote/forja.git" log --oneline feat/base 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$dir" "$remote"

  if [ "$(field "$out" published)" = "yes" ] && [ "$pushed" -ge 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (published='$(field "$out" published)' commits_on_remote=$pushed)"
  fi
}

test_merge_stays_green_when_publishing_fails() {
  local name="no remote to publish to leaves the node done and the merge green"
  local dir out json
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  (
    cd "$dir"
    git worktree add -q wt -b ship/TASK-001 feat/base
    mkdir -p wt/src
    printf 'export const a = 1\n' > wt/src/a.ts
    git -C wt add -A
    git -C wt commit -qm "feat: TASK-001"
    bash "$GRAPH" claim TASK-001 --worktree wt --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" merge TASK-001)"
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if [ "$(field "$out" result)" = "green" ] \
    && [ "$(field "$out" published)" = "skipped-no-remote" ] \
    && printf '%s' "$json" | grep -q '"status": "done"'; then
    log_pass "$name"
  else
    log_fail "$name (published='$(field "$out" published)' result='$(field "$out" result)')"
  fi
}

test_claim_writes_the_pr_marker_with_the_graph_base
test_node_pr_off_writes_no_marker
test_set_flips_node_pr_on_a_live_graph
test_pipeline_emits_the_node_pr_step_before_homolog
test_pipeline_moves_past_node_pr_once_the_pr_exists
test_no_marker_means_no_node_pr_step
test_pr_created_marker_retires_the_step
test_preflight_reports_the_graph_base_and_keep_context
test_preflight_outside_a_graph_keeps_the_default_base
test_preflight_resolves_a_remote_not_named_origin
test_green_merge_publishes_the_base
test_green_merge_publishes_to_a_remote_not_named_origin
test_merge_stays_green_when_publishing_fails

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
