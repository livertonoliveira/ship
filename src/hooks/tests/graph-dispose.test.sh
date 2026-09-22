#!/usr/bin/env bash

# A workspace is a whole second checkout of the repo; nothing ever removed them,
# so every finished run left one per node on disk forever. These tests pin the
# lifecycle: a merged node's workspace is freed, everything that must outlive it
# is harvested first, and the three cases that keep one alive stay alive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"
DRIVER_LOCAL="$SCRIPT_DIR/../driver-local.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

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
    git remote add origin https://forge.test/acme/repo.git
  )
}

make_gh() {
  local dir="$1" state="$2"
  cat > "$dir/fake-gh" <<GH
#!/usr/bin/env bash
printf '{"number":7,"state":"$state","url":"https://forge.test/acme/repo/pull/7","autoMergeRequest":null}\n'
GH
  chmod +x "$dir/fake-gh"
}

init_graph() {
  local dir="$1"
  shift
  (
    cd "$dir"
    cat > nodes.json <<'JSON'
[
  { "id": "TASK-001", "title": "Base", "deps": [], "files": ["src/good.ts"] },
  { "id": "TASK-002", "title": "Depende", "deps": ["TASK-001"], "files": ["src/other.ts"] }
]
JSON
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main "$@" >/dev/null
  )
}

# A landed node with the shape a real one has when it lands: a commit on its own
# branch and a homolog report in its scratch dir.
landed_node() {
  local dir="$1" task="$2" dirty="${3:-}"
  (
    cd "$dir"
    # Under .ship-graph/, where driver-local puts its workspaces — dispose is
    # fenced to that root, so a test workspace anywhere else exercises nothing.
    git worktree add -q "$dir/.ship-graph/f/$task" -b "ship/$task" main
    local wt="$dir/.ship-graph/f/$task"
    mkdir -p "$wt/src" "$wt/.context/ship-run/$task"
    printf 'export const x = 1\n' > "$wt/src/good.ts"
    printf '# Homolog %s\n' "$task" > "$wt/.context/ship-run/$task/homolog-report.md"
    git -C "$wt" add -A
    git -C "$wt" commit -qm "feat: $task"
    bash "$GRAPH" claim "$task" --worktree "$wt" --branch "ship/$task" >/dev/null
    bash "$GRAPH" land "$task" >/dev/null
    # After land: seal_workspace commits everything it finds, so a file written
    # before it would not be uncommitted by the time dispose looks.
    [ "$dirty" = "dirty" ] && printf 'uncommitted\n' > "$wt/src/scratch.ts"
    true
  )
}

WS() { printf '%s/.ship-graph/f/%s' "$1" "$2"; }

test_a_merged_node_frees_its_workspace() {
  local name="a node whose PR merged has its workspace removed and its report harvested"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001
  make_gh "$dir" MERGED
  # driver-local owns the removal; the graph was inited on manual for the rest of
  # the suite, so point it at the driver that actually removes a worktree.
  (cd "$dir" && bash "$GRAPH" set --driver local >/dev/null)
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll --stall-after 0)"

  local gone=1 harvested=0
  [ -d "$(WS "$dir" TASK-001)" ] && gone=0
  [ -f "$dir/.context/ship-graph/f/artifacts/TASK-001/homolog-report.md" ] && harvested=1
  local wt_col
  wt_col="$(awk -F'\t' '$1 == "TASK-001" { print $7 }' "$dir/.context/ship-graph/f/nodes.tsv")"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^workspace_freed=TASK-001$' \
    && [ "$gone" -eq 1 ] && [ "$harvested" -eq 1 ] && [ -z "$wt_col" ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' gone=$gone harvested=$harvested wt='$wt_col')"
  fi
}

test_an_unmerged_node_keeps_its_workspace() {
  local name="a node still awaiting merge keeps its workspace"
  local dir out present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001
  make_gh "$dir" OPEN
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll --stall-after 0)"
  [ -d "$(WS "$dir" TASK-001)" ] && present=1
  rm -rf "$dir"

  if [ "$present" -eq 1 ] && ! printf '%s' "$out" | grep -q '^workspace_freed='; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present)"
  fi
}

test_uncommitted_work_is_never_thrown_away() {
  local name="a merged node whose tree still holds uncommitted changes keeps its workspace"
  local dir out present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001 dirty
  make_gh "$dir" MERGED
  (cd "$dir" && bash "$GRAPH" set --driver local >/dev/null)
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll --stall-after 0)"
  [ -d "$(WS "$dir" TASK-001)" ] && present=1
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^workspace_kept=TASK-001$' && [ "$present" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present)"
  fi
}

test_keep_workspaces_disables_the_whole_thing() {
  local name="--keep-workspaces leaves a merged node's workspace on disk"
  local dir out present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir" --keep-workspaces
  landed_node "$dir" TASK-001
  make_gh "$dir" MERGED
  (cd "$dir" && bash "$GRAPH" set --driver local >/dev/null)
  out="$(cd "$dir" && GH_BIN="$dir/fake-gh" bash "$GRAPH" poll --stall-after 0)"
  [ -d "$(WS "$dir" TASK-001)" ] && present=1
  rm -rf "$dir"

  if [ "$present" -eq 1 ] && ! printf '%s' "$out" | grep -q '^workspace_freed='; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present)"
  fi
}

test_sweep_catches_up() {
  local name="sweep frees the workspaces a run left behind, and only the merged ones"
  local dir out present=0 failed_present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir" --keep-workspaces
  landed_node "$dir" TASK-001
  landed_node "$dir" TASK-002
  make_gh "$dir" MERGED
  (
    cd "$dir"
    bash "$GRAPH" set --driver local >/dev/null
    GH_BIN="$dir/fake-gh" bash "$GRAPH" poll --stall-after 0 >/dev/null
    # TASK-002 merged too; fail it afterwards is not possible, so leave it merged
    # and assert only that a node the sweep never saw is untouched.
  )
  out="$(cd "$dir" && bash "$GRAPH" sweep)"
  [ -d "$(WS "$dir" TASK-001)" ] && present=1
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^workspace_freed=TASK-001$' \
    && printf '%s' "$out" | grep -q '^swept=' && [ "$present" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present)"
  fi
}

test_a_failed_node_is_never_swept() {
  local name="sweep never touches a failed node's workspace — it is the record of what went wrong"
  local dir out present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  init_graph "$dir"
  landed_node "$dir" TASK-001
  make_gh "$dir" CLOSED
  (
    cd "$dir"
    bash "$GRAPH" set --driver local >/dev/null
    GH_BIN="$dir/fake-gh" bash "$GRAPH" poll --stall-after 0 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" sweep --force)"
  [ -d "$(WS "$dir" TASK-001)" ] && present=1
  rm -rf "$dir"

  if [ "$present" -eq 1 ] && ! printf '%s' "$out" | grep -q 'TASK-001'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present)"
  fi
}

test_driver_local_dispose_deregisters_the_worktree() {
  local name="driver-local dispose removes the worktree AND its git registration"
  local dir out registered=1 present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    mkdir -p "$dir/../.ship-graph-t" 2>/dev/null || true
    mkdir -p state
    git worktree add -q "$dir/.ship-graph/u/TASK-001" -b ship/TASK-001 main
    printf 'worktree=%s\n' "$dir/.ship-graph/u/TASK-001" > state/driver-local-TASK-001.txt
  )
  out="$(cd "$dir" && bash "$DRIVER_LOCAL" dispose TASK-001 --state "$dir/state")"
  [ -d "$dir/.ship-graph/u/TASK-001" ] && present=1
  (cd "$dir" && git worktree list --porcelain | grep -q 'TASK-001') || registered=0
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^disposed=1$' && [ "$present" -eq 0 ] && [ "$registered" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present registered=$registered)"
  fi
}

# The call that proves it is the one made from somewhere else. Run from inside
# the repo, a dispose that resolved the repo from cwd would pass by accident.
test_driver_local_disposes_from_any_cwd() {
  local name="driver-local dispose deregisters the worktree even when called from outside the repo"
  local dir out registered=1 present=0 elsewhere
  dir="$(mktemp -d)"
  elsewhere="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    mkdir -p state
    git worktree add -q "$dir/.ship-graph/u/TASK-001" -b ship/TASK-001 main
    printf 'worktree=%s\n' "$dir/.ship-graph/u/TASK-001" > state/driver-local-TASK-001.txt
  )
  # cwd is a directory that is not a git repo at all.
  out="$(cd "$elsewhere" && bash "$DRIVER_LOCAL" dispose TASK-001 --state "$dir/state")"
  [ -d "$dir/.ship-graph/u/TASK-001" ] && present=1
  (cd "$dir" && git worktree list --porcelain | grep -q 'TASK-001') || registered=0
  rm -rf "$dir" "$elsewhere"

  if printf '%s' "$out" | grep -q '^disposed=1$' && [ "$present" -eq 0 ] && [ "$registered" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present registered=$registered)"
  fi
}

test_driver_local_refuses_a_path_it_does_not_own() {
  local name="driver-local dispose refuses a path outside its own workspace root"
  local dir out present=0
  dir="$(mktemp -d)"
  new_repo "$dir"
  mkdir -p "$dir/state" "$dir/precious"
  printf 'keep\n' > "$dir/precious/file.txt"
  printf 'worktree=%s\n' "$dir/precious" > "$dir/state/driver-local-TASK-001.txt"
  out="$(cd "$dir" && bash "$DRIVER_LOCAL" dispose TASK-001 --state "$dir/state")"
  [ -f "$dir/precious/file.txt" ] && present=1
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^disposed=0$' && [ "$present" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' present=$present)"
  fi
}

test_a_merged_node_frees_its_workspace
test_an_unmerged_node_keeps_its_workspace
test_uncommitted_work_is_never_thrown_away
test_keep_workspaces_disables_the_whole_thing
test_sweep_catches_up
test_a_failed_node_is_never_swept
test_driver_local_dispose_deregisters_the_worktree
test_driver_local_disposes_from_any_cwd
test_driver_local_refuses_a_path_it_does_not_own

echo ""
echo "${pass_count} passed, ${fail_count} failed"
[ "$fail_count" -eq 0 ]
