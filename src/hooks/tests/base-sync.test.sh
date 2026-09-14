#!/usr/bin/env bash

# A run must start on the trunk the forge actually has.
#
# The regression this pins: a graph node's workspace is cut from the LOCAL base
# ref, while the graph admits that node once its dependency's PR is MERGED on
# the forge. A merge on the forge is not a commit in this clone, so the node
# opened on a trunk without the very thing it had been waiting for. Measured
# 2026-09-14 on MOB-3461: admitted on two merged PRs, opened 9 commits behind
# origin/main with neither dependency's code on disk, and only the planner's
# confrontation pass noticed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# A clone whose remote has moved on without it — a dependency's PR merging on
# the forge, seen from a workspace that was cut before it landed.
new_case() {
  local root work other
  root="$(mktemp -d)"
  git init -q --bare "$root/remote.git"
  # Pin the bare repo's HEAD instead of inheriting init.defaultBranch: on a
  # runner that still defaults to master, the second clone below checks out an
  # unborn master, its commit lands there, and `push origin main` fails with
  # "src refspec main does not match any" — which is a broken fixture wearing
  # the costume of a broken sync. `symbolic-ref` works on every git that has
  # ever shipped; `init -b` does not.
  git -C "$root/remote.git" symbolic-ref HEAD refs/heads/main

  git clone -q "$root/remote.git" "$root/work" 2>/dev/null
  work="$root/work"
  git -C "$work" config user.email t@t.com
  git -C "$work" config user.name t
  mkdir -p "$work/ship"
  printf '# Config\n- Runtime: node\n' > "$work/ship/config.md"
  echo trunk > "$work/trunk.txt"
  git -C "$work" add -A
  git -C "$work" commit -qm trunk
  git -C "$work" branch -M main
  git -C "$work" push -q origin main
  git -C "$work" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true

  git clone -q "$root/remote.git" "$root/other" 2>/dev/null
  other="$root/other"
  git -C "$other" config user.email t@t.com
  git -C "$other" config user.name t
  echo dep > "$other/dependency.txt"
  git -C "$other" add -A
  git -C "$other" commit -qm "the dependency lands on the forge"
  git -C "$other" push -q origin main

  printf '%s' "$root"
}

run_init() {
  ( cd "$1/work" && bash "$PIPELINE" init TASK-1 --mode fresh 2>&1 ) || true
}

test_a_node_opens_on_what_the_forge_has() {
  local name="a fresh run fast-forwards onto the trunk before it touches anything"
  local root out
  root="$(new_case)"
  git -C "$root/work" checkout -q -b node/TASK-1
  out="$(run_init "$root")"

  if [ ! -f "$root/work/dependency.txt" ]; then
    log_fail "$name (the dependency that admitted this node is still not on disk)"
  elif ! printf '%s' "$out" | grep -q '^base_sync=origin/main$'; then
    log_fail "$name (sync not reported: $(printf '%s' "$out" | grep '^base_sync=' || echo none))"
  else
    log_pass "$name"
  fi
  rm -rf "$root"
}

test_the_run_scratch_dir_does_not_block_the_sync() {
  local name="the run's own scratch dir does not read as a dirty tree"
  local root out
  root="$(new_case)"
  git -C "$root/work" checkout -q -b node/TASK-1
  # What a graph coordinator's claim leaves behind before the worker starts.
  mkdir -p "$root/work/.context/ship-run/TASK-1"
  printf 'defer\n' > "$root/work/.context/ship-run/TASK-1/homolog-mode.txt"
  out="$(run_init "$root")"

  # init writes this dir itself, so a porcelain check is never clean here and
  # skipped the sync every time.
  if printf '%s' "$out" | grep -q '^base_sync=skipped-dirty-tree$'; then
    log_fail "$name (untracked scratch state still counts as dirty)"
  elif [ -f "$root/work/dependency.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (no sync happened: $(printf '%s' "$out" | grep '^base_sync=' || echo none))"
  fi
  rm -rf "$root"
}

test_a_branch_with_work_is_left_alone() {
  local name="a branch already carrying commits is never moved"
  local root out before after
  root="$(new_case)"
  git -C "$root/work" checkout -q -b node/TASK-1
  echo mine > "$root/work/mine.txt"
  git -C "$root/work" add -A
  git -C "$root/work" commit -qm "work already done here"
  before="$(git -C "$root/work" rev-parse HEAD)"
  out="$(run_init "$root")"
  after="$(git -C "$root/work" rev-parse HEAD)"

  # At init, anything ahead of the base means a resume. Moving it would be a
  # rebase nobody asked for, and this runs unattended.
  if [ "$before" != "$after" ]; then
    log_fail "$name (HEAD moved from $before to $after)"
  elif ! printf '%s' "$out" | grep -q '^base_sync=skipped-branch-ahead$'; then
    log_fail "$name (the refusal was not reported: $(printf '%s' "$out" | grep '^base_sync=' || echo none))"
  else
    log_pass "$name"
  fi
  rm -rf "$root"
}

test_uncommitted_work_is_never_discarded() {
  local name="a tracked file modified in the tree stops the sync, it is not discarded"
  local root out
  root="$(new_case)"
  git -C "$root/work" checkout -q -b node/TASK-1
  echo tampered > "$root/work/trunk.txt"
  out="$(run_init "$root")"

  if [ "$(cat "$root/work/trunk.txt")" != "tampered" ]; then
    log_fail "$name (the edit was lost)"
  elif ! printf '%s' "$out" | grep -q '^base_sync=skipped-dirty-tree$'; then
    log_fail "$name (the refusal was not reported: $(printf '%s' "$out" | grep '^base_sync=' || echo none))"
  else
    log_pass "$name"
  fi
  rm -rf "$root"
}

test_no_remote_is_not_a_failure() {
  local name="a repo with no remote runs exactly as before"
  local root out
  root="$(mktemp -d)"
  git init -q "$root/work"
  git -C "$root/work" config user.email t@t.com
  git -C "$root/work" config user.name t
  mkdir -p "$root/work/ship"
  printf '# Config\n- Runtime: node\n' > "$root/work/ship/config.md"
  echo x > "$root/work/a.txt"
  git -C "$root/work" add -A
  git -C "$root/work" commit -qm one
  out="$(run_init "$root")"

  if ! printf '%s' "$out" | grep -q '^INIT fresh$'; then
    log_fail "$name (init did not complete: $out)"
  elif ! printf '%s' "$out" | grep -q '^base_sync=skipped-no-remote$'; then
    log_fail "$name (the skip was not reported: $(printf '%s' "$out" | grep '^base_sync=' || echo none))"
  else
    log_pass "$name"
  fi
  rm -rf "$root"
}

test_a_node_opens_on_what_the_forge_has
test_the_run_scratch_dir_does_not_block_the_sync
test_a_branch_with_work_is_left_alone
test_uncommitted_work_is_never_discarded
test_no_remote_is_not_a_failure

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
