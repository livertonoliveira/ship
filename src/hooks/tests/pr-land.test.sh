#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAND="$SCRIPT_DIR/../pr-land.sh"

pass_count=0
fail_count=0
log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# result lines carry several key=value pairs; take one key's value.
field() { printf '%s\n' "$1" | grep -oE "(^| )$2=[^ ]*" | head -1 | sed -E "s/^ *$2=//"; }

# A fake forge client: records argv, answers `pr create` with a URL and
# `pr view <branch>` with whatever GH_FAKE_PR_STATE holds (empty = no PR).
fake_gh() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_FAKE_LOG"
case "$1 $2" in
  "pr create")
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$GH_FAKE_BODY"; shift; done
    echo "https://github.com/acme/repo/pull/42" ;;
  "pr view")
    if [ -n "${GH_FAKE_PR_OID:-}" ]; then
      printf '{"url":"https://github.com/acme/repo/pull/42","number":42,"state":"%s","headRefOid":"%s"}\n' "${GH_FAKE_PR_STATE:-MERGED}" "$GH_FAKE_PR_OID"
    elif [ -n "${GH_FAKE_PR_STATE:-}" ]; then printf '%s\n' "$GH_FAKE_PR_STATE"
    else exit 1; fi ;;
  "pr merge") exit "${GH_FAKE_MERGE_EXIT:-0}" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
}

# A repo with a bare remote, a task branch holding two conventional commits,
# and a graph node's scratch dir (pr-mode.txt marks the node, base = main).
setup() {
  local root="$1" task="${2:-T1}"
  mkdir -p "$root/remote.git" "$root/repo"
  git init -q --bare "$root/remote.git"
  (
    cd "$root/repo"
    git init -q -b main .
    git config user.email t@t; git config user.name T
    mkdir ship; printf '# Config\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n- Test Framework: none\n' > ship/config.md
    printf '.context/\n' > .gitignore
    echo base > a.txt
    git add -A; git commit -qm init
    git remote add origin "$root/remote.git"
    git push -q -u origin main
    git checkout -q -b "fix/$task-x"
    echo one > one.txt; git add one.txt; git commit -qm "fix: handle the empty case"
    echo two > two.txt; git add two.txt; git commit -qm "test: cover the empty case"
    mkdir -p ".context/ship-run/$task/linear"
    printf 'mode=graph\nbase=main\n' > ".context/ship-run/$task/pr-mode.txt"
    printf '# %s — Empty rows must not crash the exporter\n\nbody\n' "$task" > ".context/ship-run/$task/linear/issue.md"
    printf '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n|---|---|---|---|---|---|---|---|---|---|\n| dev | #1 | t | - | pass | 0 | 0 | 0 | 0 | |\n| review | #1 | t | - | warn | 0 | 0 | 1 | 2 | |\n' > ".context/ship-run/$task/phase-status.md"
  ) >/dev/null 2>&1
  fake_gh "$root"
}

land() { local root="$1"; shift; (cd "$root/repo" && GH_FAKE_LOG="$root/gh.log" GH_FAKE_BODY="$root/body.md" PATH="$root/bin:$PATH" bash "$LAND" "$@"); }

# Measured on 37 graph nodes: the PR step was 9.6 of 26 orchestrating turns.
test_a_committed_branch_lands_in_one_call() {
  local name="checks, sync, push, title and body from disk, PR, auto-merge, finalize — one call, result=landed"
  local root; root="$(mktemp -d)"; setup "$root"
  local out rc=0; out="$(land "$root" T1)" || rc=$?
  local title; title="$(grep -oE -- '--title [^-]*' "$root/gh.log" | head -1)"
  if [ "$rc" -eq 0 ] && [ "$(field "$out" result)" = "landed" ] \
    && [ "$(field "$out" pr)" = "https://github.com/acme/repo/pull/42" ] && [ "$(field "$out" number)" = "42" ] \
    && [ "$(field "$out" automerge)" = "armed" ] && [ "$(field "$out" linear)" = "skipped" ] \
    && grep -q -- '^pr create --base main --head fix/T1-x --title' "$root/gh.log" \
    && grep -q -- '^pr merge --auto --squash fix/T1-x' "$root/gh.log" \
    && printf '%s' "$title" | grep -q 'fix: Empty rows must not crash the exporter (T1)' \
    && grep -q -- '- fix: handle the empty case' "$root/body.md" \
    && grep -q -- '| review | WARN | 0 | 0 | 1 | 2 |' "$root/body.md" \
    && grep -q '^Closes T1$' "$root/body.md" \
    && [ -f "$root/repo/.context/ship-run/T1/pr-created.txt" ] \
    && [ "$(git -C "$root/remote.git" rev-parse fix/T1-x)" = "$(git -C "$root/repo" rev-parse HEAD)" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out title='$title' log=$(tr '\n' '|' < "$root/gh.log" 2>/dev/null) body=$(tr '\n' '|' < "$root/body.md" 2>/dev/null | cut -c1-300))"
  fi
  rm -rf "$root"
}

test_uncommitted_changes_are_handed_back_first() {
  local name="pending changes → result=uncommitted, exit 2, nothing pushed"
  local root; root="$(mktemp -d)"; setup "$root"
  echo dirty > "$root/repo/one.txt"
  local out rc=0; out="$(land "$root" T1)" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$(field "$out" result)" = "uncommitted" ] && [ ! -f "$root/gh.log" ] \
    && ! git -C "$root/remote.git" rev-parse -q --verify fix/T1-x >/dev/null 2>&1; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$root"
}

test_a_stale_retry_branch_is_overwritten_with_a_lease() {
  local name="a remote branch from an earlier attempt, with no PR, is overwritten with a lease — the name the graph tracks stays"
  local root; root="$(mktemp -d)"; setup "$root"
  ( cd "$root/repo" && git checkout -q -b tmp main && echo old > old.txt && git add old.txt && git commit -qm "old attempt" \
    && git push -q origin tmp:fix/T1-x && git checkout -q fix/T1-x && git branch -q -D tmp ) >/dev/null 2>&1
  local out rc=0; out="$(land "$root" T1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(field "$out" result)" = "landed" ] && [ "$(field "$out" branch)" = "fix/T1-x" ] \
    && [ "$(git -C "$root/remote.git" rev-parse fix/T1-x)" = "$(git -C "$root/repo" rev-parse HEAD)" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$root"
}

test_a_graph_node_updates_its_own_open_pr_after_a_rebase() {
  local name="graph node: an OPEN PR on the task branch with other history is this node's earlier landing — the branch is pushed with a lease and the PR is reused"
  local root; root="$(mktemp -d)"; setup "$root"
  ( cd "$root/repo" && git checkout -q -b tmp main && echo old > old.txt && git add old.txt && git commit -qm "earlier landing" \
    && git push -q origin tmp:fix/T1-x && git checkout -q fix/T1-x && git branch -q -D tmp ) >/dev/null 2>&1
  local out rc=0; out="$(cd "$root/repo" && GH_FAKE_LOG="$root/gh.log" GH_FAKE_BODY="$root/body.md" GH_FAKE_PR_OID=1111111111111111111111111111111111111111 GH_FAKE_PR_STATE=OPEN PATH="$root/bin:$PATH" bash "$LAND" T1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(field "$out" result)" = "landed" ] && [ "$(field "$out" branch)" = "fix/T1-x" ] \
    && [ "$(git -C "$root/remote.git" rev-parse fix/T1-x)" = "$(git -C "$root/repo" rev-parse HEAD)" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$root"
}

test_a_standalone_run_never_overwrites_a_remote_branch() {
  local name="standalone (no graph marker): a remote branch with other history → result=remote-branch-exists, exit 5, no force-push"
  local root; root="$(mktemp -d)"; setup "$root"
  rm -f "$root/repo/.context/ship-run/T1/pr-mode.txt"
  ( cd "$root/repo" && git checkout -q -b tmp main && echo old > old.txt && git add old.txt && git commit -qm "old attempt" \
    && git push -q origin tmp:fix/T1-x && git checkout -q fix/T1-x && git branch -q -D tmp ) >/dev/null 2>&1
  local old; old="$(git -C "$root/remote.git" rev-parse fix/T1-x)"
  local out rc=0; out="$(cd "$root/repo" && GH_FAKE_LOG="$root/gh.log" GH_FAKE_BODY="$root/body.md" PATH="$root/bin:$PATH" bash "$LAND" T1)" || rc=$?
  if [ "$rc" -eq 5 ] && [ "$(field "$out" result)" = "remote-branch-exists" ] \
    && [ "$(git -C "$root/remote.git" rev-parse fix/T1-x)" = "$old" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$root"
}

test_a_failed_automerge_is_reported_not_fatal() {
  local name="auto-merge the forge refuses is reported as automerge=failed; the PR still lands"
  local root; root="$(mktemp -d)"; setup "$root"
  local out rc=0; out="$(cd "$root/repo" && GH_FAKE_LOG="$root/gh.log" GH_FAKE_BODY="$root/body.md" GH_FAKE_MERGE_EXIT=1 PATH="$root/bin:$PATH" bash "$LAND" T1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(field "$out" result)" = "landed" ] && [ "$(field "$out" automerge)" = "failed" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$root"
}

# Measured live (MOB-7912): the first run's output was lost in hook noise, the
# second saw a merged PR on the branch, reported "exists", and the node stopped
# with its PR merged and the pipeline never told.
test_a_second_run_over_its_own_landed_pr_is_landed_again() {
  local name="a PR on the branch whose head is our HEAD is ours — the re-run reports landed (reused=1), pushes nothing, finalizes"
  local root; root="$(mktemp -d)"; setup "$root"
  local oid; oid="$(git -C "$root/repo" rev-parse HEAD)"
  local out rc=0; out="$(cd "$root/repo" && GH_FAKE_LOG="$root/gh.log" GH_FAKE_BODY="$root/body.md" GH_FAKE_PR_OID="$oid" GH_FAKE_PR_STATE=MERGED PATH="$root/bin:$PATH" bash "$LAND" T1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(field "$out" result)" = "landed" ] && [ "$(field "$out" reused)" = "1" ] \
    && [ "$(field "$out" number)" = "42" ] && ! grep -q '^pr create' "$root/gh.log" \
    && ! git -C "$root/remote.git" rev-parse -q --verify fix/T1-x >/dev/null 2>&1 \
    && [ -f "$root/repo/.context/ship-run/T1/pr-created.txt" ] \
    && grep -q '^result=landed' "$root/repo/.context/ship-run/T1/pr-land.txt"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out log=$(tr '\n' '|' < "$root/gh.log" 2>/dev/null))"
  fi
  rm -rf "$root"
}

test_the_result_line_is_also_on_disk() {
  local name="a landed run writes its result line to <scratch>/pr-land.txt for a caller whose output got lost"
  local root; root="$(mktemp -d)"; setup "$root"
  land "$root" T1 >/dev/null 2>&1 || true
  if grep -q '^result=landed pr=https://github.com/acme/repo/pull/42' "$root/repo/.context/ship-run/T1/pr-land.txt"; then
    log_pass "$name"
  else
    log_fail "$name ($(cat "$root/repo/.context/ship-run/T1/pr-land.txt" 2>/dev/null))"
  fi
  rm -rf "$root"
}

test_a_merged_pr_on_the_task_branch_is_landed_whatever_our_head_is() {
  local name="a MERGED PR on the task's branch is this task landed even after a squash moved our HEAD — landed (reused=1)"
  local root; root="$(mktemp -d)"; setup "$root"
  local out rc=0; out="$(cd "$root/repo" && GH_FAKE_LOG="$root/gh.log" GH_FAKE_BODY="$root/body.md" GH_FAKE_PR_OID=0000000000000000000000000000000000000000 GH_FAKE_PR_STATE=MERGED PATH="$root/bin:$PATH" bash "$LAND" T1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(field "$out" result)" = "landed" ] && [ "$(field "$out" reused)" = "1" ] && ! grep -q '^pr create' "$root/gh.log"; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out)"
  fi
  rm -rf "$root"
}

test_a_committed_branch_lands_in_one_call
test_a_merged_pr_on_the_task_branch_is_landed_whatever_our_head_is
test_a_second_run_over_its_own_landed_pr_is_landed_again
test_the_result_line_is_also_on_disk
test_uncommitted_changes_are_handed_back_first
test_a_stale_retry_branch_is_overwritten_with_a_lease
test_a_graph_node_updates_its_own_open_pr_after_a_rebase
test_a_standalone_run_never_overwrites_a_remote_branch
test_a_failed_automerge_is_reported_not_fatal

echo ""
echo "${pass_count} passed, ${fail_count} failed"
[ "$fail_count" -eq 0 ]
