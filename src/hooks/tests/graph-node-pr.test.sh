#!/usr/bin/env bash

# One issue, one workspace, one PR. Three seams carry that, and each is easy to
# break silently:
#
#   * claim writes the pr-mode marker (carrying the graph's base — the branch the
#     forge really merges into) into the node's scratch dir, the only place the
#     node's own pipeline can learn it is running inside a graph;
#   * pipeline.sh turns that marker into a node-pr step BEFORE homolog, because
#     homolog-approved.txt is what the graph polls to land and seal;
#   * pr-sync.sh rebases the node onto that base before the push, and hands a
#     conflict back to the agent that wrote the change instead of to anyone else.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"
PR_PREFLIGHT="$SCRIPT_DIR/../pr-preflight.sh"
PR_FINALIZE="$SCRIPT_DIR/../pr-finalize.sh"
PR_SYNC="$SCRIPT_DIR/../pr-sync.sh"

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

# Measured on 61 nodes: at done the model sent worker_done and narrated a
# summary nobody reads — two turns per node. The pipeline now runs the signal
# the driver left in on-done.sh and tells the node to end its turn.
# pr-land.sh proved the tree again and found it red. Measured 2026-10-15
# (MOB-8075): the pipeline failed the node on the spot, 16 s after its own PR
# merged, with no fix attempted. A red at landing gets one fix round while the
# node's remediation cap allows it; past the cap it fails with that reason.
landing_red_node() {
  local dir="$1" scratch="$1/.context/ship-run/T1"
  pipeline_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=feat/base\n' > "$scratch/pr-mode.txt"
  printf '/graph\n' > "$scratch/graph-node.txt"
  printf 'defer\n' > "$scratch/homolog-mode.txt"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  printf 'result=red exit=1 report=%s/test-failures.md\n' "$scratch" > "$scratch/pr-land.txt"
  printf '| test | #1 | 2026-10-15T01:25:00Z | - | fail | 0 | 0 | 0 | 0 | |\n' > "$scratch/phase-status-test.md"
  printf '# Test Failures\n\n## Test suite failed\n\n```\nFAIL test/a.spec.js\n```\n' > "$scratch/test-failures.md"
}

test_a_red_at_landing_gets_a_fix_round() {
  local name="checks red at landing dispatch one fix agent while the remediation cap allows, instead of failing the node on the spot"
  local dir out scratch
  dir="$(mktemp -d)"
  landing_red_node "$dir"
  scratch="$dir/.context/ship-run/T1"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  local inflight="no"; [ -f "$scratch/remediation-fix-inflight.txt" ] && inflight="yes"
  local failed="no"; [ -f "$scratch/node-failed.txt" ] && failed="yes"
  local landfile="gone"; [ -f "$scratch/pr-land.txt" ] && landfile="kept"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "remediation-fix" ] && [ "$inflight" = "yes" ] && [ "$failed" = "no" ] && [ "$landfile" = "gone" ] \
    && printf '%s' "$out" | grep -q 'ship-remediation-fix'; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) inflight=$inflight failed=$failed pr-land=$landfile)"
  fi
}

test_a_red_at_landing_past_the_cap_fails_with_its_reason() {
  local name="checks red at landing with the remediation cap spent fail the node, naming the landing, never a stale 'after remediation'"
  local dir out scratch
  dir="$(mktemp -d)"
  landing_red_node "$dir"
  scratch="$dir/.context/ship-run/T1"
  printf '2\n' > "$scratch/iteration-graph-remediation-rounds.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  local reason; reason="$(cat "$scratch/node-failed.txt" 2>/dev/null)"
  local inflight="no"; [ -f "$scratch/remediation-fix-inflight.txt" ] && inflight="yes"
  rm -rf "$dir"
  if [ "$(field "$out" action)" = "stop" ] && [ "$inflight" = "no" ] \
    && printf '%s' "$reason" | grep -q 'red at landing'; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) action=$(field "$out" action) inflight=$inflight reason='$reason')"
  fi
}

# Measured on 36 nodes: the commits-and-PR window took 8.7 of 15.6 turns. Once
# the tree is committed, next runs pr-land.sh itself and reads its result.
landing_repo() {
  local root="$1"
  mkdir -p "$root/remote.git" "$root/repo" "$root/bin"
  git init -q --bare "$root/remote.git"
  (
    cd "$root/repo"
    git init -q -b main .
    git config user.email t@t; git config user.name T
    mkdir ship
    printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n## Test Scope\n- unit: disabled\n- integration: disabled\n- e2e: disabled\n\n- Test Framework: none\n' > ship/config.md
    printf '.context/\n' > .gitignore
    echo base > a.txt
    git add -A; git commit -qm init
    git remote add origin "$root/remote.git"
    git push -q -u origin main
    git checkout -q -b fix/T1-x
    echo one > one.txt; git add one.txt; git commit -qm "fix: handle the empty case"
  ) >/dev/null 2>&1
  cat > "$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_FAKE_LOG:?}"
case "$1 $2" in
  "pr create") echo "https://github.com/acme/repo/pull/42" ;;
  "pr view") exit 1 ;;
  "pr merge") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$root/bin/gh"
}

test_a_committed_tree_is_landed_by_next_itself() {
  local name="once the tree is committed, next runs pr-land.sh itself: the PR is created, pr-created.txt holds the result and the node reaches done in that same call"
  local root out scratch
  root="$(mktemp -d)"
  landing_repo "$root"
  (cd "$root/repo" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$root/repo/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=main\n' > "$scratch/pr-mode.txt"
  printf '/graph\n' > "$scratch/graph-node.txt"
  printf 'defer\n' > "$scratch/homolog-mode.txt"
  (cd "$root/repo" && PATH="$root/bin:$PATH" GH_FAKE_LOG="$root/gh.log" bash "$PIPELINE" next T1) >/dev/null
  out="$(cd "$root/repo" && PATH="$root/bin:$PATH" GH_FAKE_LOG="$root/gh.log" bash "$PIPELINE" next T1)"
  local created="no"; [ -s "$scratch/pr-created.txt" ] && created="yes"
  local landed; landed="$(cat "$scratch/pr-land.txt" 2>/dev/null || true)"
  local creates; creates="$(grep -c '^pr create' "$root/gh.log" 2>/dev/null || true)"
  rm -rf "$root"
  if [ "$(field "$out" state)" = "done" ] && [ "$created" = "yes" ] \
    && printf '%s' "$landed" | grep -q '^result=landed pr=https://github.com/acme/repo/pull/42' \
    && [ "${creates:-0}" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) created=$created landed='$landed' creates=$creates)"
  fi
}

test_an_uncommitted_tree_is_handed_to_the_model_first() {
  local name="with pending changes, next asks for the atomic commits and runs no pr-land"
  local root out scratch
  root="$(mktemp -d)"
  landing_repo "$root"
  (cd "$root/repo" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$root/repo/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=main\n' > "$scratch/pr-mode.txt"
  printf '/graph\n' > "$scratch/graph-node.txt"
  printf 'defer\n' > "$scratch/homolog-mode.txt"
  echo dirty > "$root/repo/two.txt"
  (cd "$root/repo" && PATH="$root/bin:$PATH" GH_FAKE_LOG="$root/gh.log" bash "$PIPELINE" next T1) >/dev/null
  out="$(cd "$root/repo" && PATH="$root/bin:$PATH" GH_FAKE_LOG="$root/gh.log" bash "$PIPELINE" next T1)"
  local creates; creates="$(grep -c '^pr create' "$root/gh.log" 2>/dev/null || true)"
  rm -rf "$root"
  if [ "$(field "$out" state)" = "node-pr" ] && printf '%s' "$out" | grep -q 'atomic Conventional Commits' && [ "${creates:-0}" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) creates=$creates)"
  fi
}

test_an_empty_landing_completes_the_pr_step() {
  local name="pr-land's result=empty completes the node-pr step: the node reaches done with pr-empty.txt and no PR"
  local dir out scratch
  dir="$(mktemp -d)"
  pipeline_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$dir/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=feat/base\n' > "$scratch/pr-mode.txt"
  printf '/graph\n' > "$scratch/graph-node.txt"
  printf 'defer\n' > "$scratch/homolog-mode.txt"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  printf 'result=empty base=feat/base branch=ship/T1-2\n' > "$scratch/pr-land.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  local created; created="$(cat "$scratch/pr-created.txt" 2>/dev/null)"
  local empty="no"; [ -s "$scratch/pr-empty.txt" ] && empty="yes"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "done" ] && [ "$created" = "empty" ] && [ "$empty" = "yes" ]; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) created=$created empty=$empty)"
  fi
}

test_a_graph_node_done_runs_on_done_and_ends_the_turn() {
  local name="a graph node's done runs <scratch>/on-done.sh and asks for no summary; a standalone run keeps its report"
  local dir out scratch
  dir="$(mktemp -d)"
  pipeline_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  scratch="$dir/.context/ship-run/T1"
  printf '## Files\n- src/a.js\n- src/b.js\n\nTwo modules\n' > "$scratch/spec.md"
  printf 'mode=graph\nbase=feat/base\n' > "$scratch/pr-mode.txt"
  printf '/graph\n' > "$scratch/graph-node.txt"
  printf 'defer\n' > "$scratch/homolog-mode.txt"
  printf '#!/usr/bin/env sh\necho woke > "%s/woke.txt"\n' "$dir" > "$scratch/on-done.sh"; chmod +x "$scratch/on-done.sh"
  (cd "$dir" && bash "$PIPELINE" next T1) >/dev/null
  printf 'created\n' > "$scratch/pr-created.txt"
  out="$(cd "$dir" && bash "$PIPELINE" next T1)"
  local woke="no"; [ -f "$dir/woke.txt" ] && woke="yes"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "done" ] && [ "$woke" = "yes" ] \
    && printf '%s' "$out" | grep -q 'end your turn now' \
    && ! printf '%s' "$out" | grep -q 'run /ship:pr'; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) woke=$woke)"
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

# Whoever is behind rebases, with the context that wrote the change. These pin
# the two outcomes the node's own pipeline has to act on.
test_sync_rebases_onto_the_base() {
  local name="pr-sync fast-forwards the node's branch onto the base it will target"
  local dir remote out has_base=0
  dir="$(mktemp -d)"
  remote="$(mktemp -d)"
  git init -q --bare "$remote/origin.git"
  new_repo "$dir"
  (
    cd "$dir"
    git checkout -q main
    git remote add origin "$remote/origin.git"
    git push -q -u origin main
    git checkout -q -b ship/TASK-001
    printf 'node\n' > node.txt
    git add -A && git commit -qm "feat: node"
    # The base moves on underneath, in a file the node never touched.
    git checkout -q main
    printf 'trunk\n' > trunk.txt
    git add -A && git commit -qm "feat: trunk"
    git push -q origin main
    git checkout -q ship/TASK-001
  )
  out="$(cd "$dir" && bash "$PR_SYNC" --remote origin --base main)"
  git -C "$dir" show "ship/TASK-001:trunk.txt" >/dev/null 2>&1 && has_base=1
  rm -rf "$dir" "$remote"

  if [ "$(field "$out" result)" = "clean" ] && [ "$has_base" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (result='$(field "$out" result)' base_commit_present=$has_base)"
  fi
}

test_sync_hands_the_conflict_back_with_the_files() {
  local name="a conflicting rebase reports every unmerged path and leaves it resolvable in place"
  local dir remote out
  dir="$(mktemp -d)"
  remote="$(mktemp -d)"
  git init -q --bare "$remote/origin.git"
  new_repo "$dir"
  (
    cd "$dir"
    git checkout -q main
    git remote add origin "$remote/origin.git"
    printf 'shared\n' > shared.css
    git add -A && git commit -qm "feat: shared"
    git push -q -u origin main
    git checkout -q -b ship/TASK-001
    printf 'node side\n' > shared.css
    git add -A && git commit -qm "feat: node"
    git checkout -q main
    printf 'trunk side\n' > shared.css
    git add -A && git commit -qm "feat: trunk"
    git push -q origin main
    git checkout -q ship/TASK-001
  )
  out="$(cd "$dir" && bash "$PR_SYNC" --remote origin --base main)"
  # Resolve it the way the node's own agent would, then continue.
  printf 'both sides\n' > "$dir/shared.css"
  local cont
  cont="$(cd "$dir" && bash "$PR_SYNC" --continue)"
  rm -rf "$dir" "$remote"

  if [ "$(field "$out" result)" = "conflict" ] \
    && printf '%s' "$out" | grep -q '^conflict:shared.css$' \
    && [ "$(field "$cont" result)" = "clean" ]; then
    log_pass "$name"
  else
    log_fail "$name (result='$(field "$out" result)' continue='$(field "$cont" result)')"
  fi
}

test_sync_without_a_remote_is_not_an_error() {
  local name="no remote means nothing to sync against, not a failed PR"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  out="$(cd "$dir" && bash "$PR_SYNC" --base main)"
  rm -rf "$dir"

  if [ "$(field "$out" result)" = "skipped-no-remote" ]; then
    log_pass "$name"
  else
    log_fail "$name (result='$(field "$out" result)')"
  fi
}

test_claim_writes_the_pr_marker_with_the_graph_base
test_node_pr_off_writes_no_marker
test_set_flips_node_pr_on_a_live_graph
test_pipeline_emits_the_node_pr_step_before_homolog
test_a_red_at_landing_gets_a_fix_round
test_a_red_at_landing_past_the_cap_fails_with_its_reason
test_a_committed_tree_is_landed_by_next_itself
test_an_uncommitted_tree_is_handed_to_the_model_first
test_an_empty_landing_completes_the_pr_step
test_a_graph_node_done_runs_on_done_and_ends_the_turn
test_pipeline_moves_past_node_pr_once_the_pr_exists
test_no_marker_means_no_node_pr_step
test_pr_created_marker_retires_the_step
test_preflight_reports_the_graph_base_and_keep_context
test_preflight_outside_a_graph_keeps_the_default_base
test_preflight_resolves_a_remote_not_named_origin
test_sync_rebases_onto_the_base
test_sync_hands_the_conflict_back_with_the_files
test_sync_without_a_remote_is_not_an_error

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
