#!/usr/bin/env bash

# pr-land.sh — everything after the commits, in one call.
#
#   pr-land.sh <task-id> [--config <ship/config.md>] [--summary <file>] [--title <t>]
#
# Measured on 37 graph nodes (2026-10-14): the PR step took 9.6 of a node's 26
# orchestrating turns — 37% of the orchestration bill — at 75-100k tokens of
# context each, for work that is the same every time: run the checks, sync onto
# the base, push, write a title and a body from what is already on disk, open
# the PR, arm auto-merge, link it in Linear, finalize the scratch dir. Only the
# commits need judgment (which files make one logical change), so only they
# stay with the model.
#
# Run from the repo root with every change committed. Prints `result=<r>` plus
# the facts the caller acts on:
#   result=uncommitted files=<n>         commit first, then call again
#   result=red                           checks failed — <scratch>/test-failures.md
#   result=conflict files=<a,b>          rebase stopped — resolve, pr-sync.sh --continue, call again
#   result=remote-branch-exists          the remote branch has other history — the caller decides
#   result=empty base=<b> branch=<br>    no commit ahead of the base after the sync — nothing to open
#   result=landed pr=<url> number=<n> branch=<b> automerge=armed|failed|skipped linear=done|mcp-needed|skipped context=<finalize>
# Exit 0 on landed, 2 on uncommitted, 3 on red, 4 on conflict, 5 on push refused,
# 1 on anything the caller cannot act on (message on stderr).

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${GH_BIN:-gh}"
# Whatever still slips through set -e says so instead of printing nothing.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "pr-land.sh: aborted at line $LINENO (exit $rc)" >&2' EXIT

usage() { echo "usage: pr-land.sh <task-id> [--config <path>] [--summary <file>] [--title <text>]" >&2; }

task="" config="ship/config.md" summary="" title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *) if [ -z "$task" ]; then task="$1"; else usage; exit 1; fi; shift ;;
  esac
done
[ -n "$task" ] || { usage; exit 1; }
case "$task" in *[!A-Za-z0-9_-]*) echo "pr-land.sh: invalid task id: $task" >&2; exit 1 ;; esac
scratch=".context/ship-run/$task"

# Every lookup below is a grep that may match nothing; under set -e/pipefail an
# empty match must be an empty value, never a silent exit — measured live on
# three nodes whose pr-land printed nothing and whose PRs landed untold.
field() { { printf '%s\n' "$1" | grep -m1 "^$2=" || true; } | cut -d= -f2-; }

pre="$(bash "$HOOK_DIR/pr-preflight.sh" --task "$task" --config "$config")"
storage="$(field "$pre" storage)"
branch="$(field "$pre" branch)"
remote="$(field "$pre" remote)"
pr_base="$(field "$pre" pr_base)"
keep_context="$(field "$pre" keep_context)"
pending="$(field "$pre" pending_changes)"
verified="$(field "$pre" verified_tree)"

if [ "${pending:-0}" -gt 0 ]; then
  printf 'result=uncommitted files=%s\n' "$pending"
  exit 2
fi
[ -n "$remote" ] || { echo "pr-land.sh: no git remote — nothing to push to" >&2; exit 1; }
if [ "$branch" = "$pr_base" ] || [ "$branch" = "HEAD" ]; then
  echo "pr-land.sh: on $branch — create the task branch first (git checkout -b <type>/<task>-<slug>)" >&2
  exit 1
fi

# --- checks (skipped when the pipeline already proved this exact tree) --------
if [ "$verified" != "yes" ]; then
  rc=0
  bash "$HOOK_DIR/test-exec.sh" "$scratch" --config "$config" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|2) ;;
    *) printf 'result=red exit=%s report=%s/test-failures.md\n' "$rc" "$scratch"; exit 3 ;;
  esac
fi

# --- sync onto the base ---------------------------------------------------------
sync_out="$(bash "$HOOK_DIR/pr-sync.sh" --remote "$remote" --base "$pr_base" 2>/dev/null || true)"
sync_result="$(field "$sync_out" result)"
if [ "$sync_result" = "conflict" ]; then
  printf 'result=conflict files=%s\n' "$(printf '%s\n' "$sync_out" | { grep '^conflict:' || true; } | sed 's/^conflict://' | paste -sd, -)"
  exit 4
fi
# A rebase moved the tree the checks were proven on: prove it again.
if [ "$sync_result" = "clean" ] && [ "$verified" = "yes" ]; then
  rc=0
  bash "$HOOK_DIR/test-exec.sh" "$scratch" --config "$config" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|2) ;; *) printf 'result=red exit=%s report=%s/test-failures.md\n' "$rc" "$scratch"; exit 3 ;; esac
fi

# --- nothing to land ----------------------------------------------------------------
# A retried node whose first attempt already merged, or a task someone finished
# on the base meanwhile, rebases onto the base and has no commit left. There is
# no PR to open; the caller decides what that means (the graph checks the
# earlier attempt's PR). Measured 2026-10-15: a node sat 55 minutes here.
if base_ref="$(git rev-parse -q --verify "refs/remotes/$remote/$pr_base" 2>/dev/null)" && [ -n "$base_ref" ]; then
  if [ "$(git rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 1)" -eq 0 ]; then
    line="result=empty base=$pr_base branch=$branch"
    [ -d "$scratch" ] && printf '%s\n' "$line" > "$scratch/pr-land.txt"
    printf '%s\n' "$line"
    exit 6
  fi
fi

# --- an earlier run already landed this exact tree -----------------------------------
# Measured live: the first run's output was lost in the caller's hook noise, the
# second run saw a merged PR on the branch and reported "exists" — and the
# node stopped with its PR merged. A PR whose head is our HEAD is ours.
existing="$("$GH" pr view "$branch" --json url,number,state,headRefOid 2>/dev/null || true)"
if [ -n "$existing" ]; then
  ex_oid="$(printf '%s' "$existing" | { grep -oE '"headRefOid":"[0-9a-f]+"' || true; } | cut -d'"' -f4)"
  ex_state="$(printf '%s' "$existing" | { grep -oE '"state":"[A-Z]+"' || true; } | cut -d'"' -f4)"
  # The branch is this task's: a PR merged from it IS this task landed (after a
  # squash merge our HEAD is the squash commit, so the head oid no longer tells).
  # An open PR counts only when its head is our HEAD.
  if [ "$ex_state" = "MERGED" ] || [ "$ex_oid" = "$(git rev-parse HEAD)" ]; then
    pr_url="$(printf '%s' "$existing" | { grep -oE '"url":"[^"]+"' || true; } | cut -d'"' -f4)"
    number="${pr_url##*/}"
    automerge="skipped"
    if [ "$keep_context" = "yes" ] && [ "$ex_state" = "OPEN" ]; then
      if "$GH" pr merge --auto --squash "$branch" >/dev/null 2>&1; then automerge="armed"; else automerge="failed"; fi
    fi
    fin_args=(); [ "$keep_context" = "yes" ] && fin_args+=(--keep-context)
    fin_out="$(bash "$HOOK_DIR/pr-finalize.sh" "$task" ${fin_args[@]+"${fin_args[@]}"} 2>/dev/null || true)"
    line="result=landed pr=$pr_url number=$number branch=$branch automerge=$automerge linear=already context=$(field "$fin_out" context) reused=1"
    [ -d "$scratch" ] && printf '%s\n' "$line" > "$scratch/pr-land.txt"
    printf '%s\n' "$line"
    exit 0
  fi
fi

# --- push ---------------------------------------------------------------------------
# The graph tracks a node by this branch name (poll runs `pr view <branch>`),
# so the branch is never renamed. A remote branch with other history is a
# previous attempt of the same task: overwritten with a lease when no PR is
# open for it, handed back to the caller when one is.
if ! push_err="$(git push -u "$remote" "$branch" 2>&1 >/dev/null)"; then
  if printf '%s' "$push_err" | grep -qiE 'non-fast-forward|fetch first|rejected'; then
    open_pr="$("$GH" pr view "$branch" --json state --jq .state 2>/dev/null || true)"
    # A graph node owns its task branch by construction: an OPEN PR there is
    # this node's own earlier landing (a later commit, a rebase onto a moved
    # base), so the branch is updated with a lease and the PR follows. Measured
    # live: a node that re-ran after one more commit was told "exists" over its
    # own PR and stopped. A merged PR was already returned as landed above.
    if [ "$keep_context" = "yes" ] && [ "$open_pr" != "MERGED" ]; then
      git fetch -q "$remote" "$branch" 2>/dev/null || true
      lease="$(git rev-parse -q --verify "refs/remotes/$remote/$branch" 2>/dev/null || true)"
      if ! git push -u "--force-with-lease=$branch:${lease:-}" "$remote" "$branch" >/dev/null 2>&1; then
        printf 'result=remote-branch-exists branch=%s pr_state=%s\n' "$branch" "${open_pr:-none}"
        exit 5
      fi
    else
      printf 'result=remote-branch-exists branch=%s pr_state=%s\n' "$branch" "${open_pr:-none}"
      exit 5
    fi
  else
    echo "pr-land.sh: push failed: $push_err" >&2
    exit 1
  fi
fi

# --- title and body, from what is already on disk ------------------------------------
commits="$(git log --reverse --format='%s%n%b%n--' "$remote/$pr_base..HEAD" 2>/dev/null || true)"
subjects="$(git log --reverse --format='%s' "$remote/$pr_base..HEAD" 2>/dev/null || true)"
if [ -z "$title" ]; then
  # The PR's type is the change's, not its tests': test/docs/chore count only
  # when nothing else was committed; ties go to the earliest commit.
  types="$(printf '%s\n' "$subjects" | { grep -oE '^[a-z]+(\([^)]*\))?!?:' || true; } | sed -E 's/[(!:].*//')"
  main_types="$(printf '%s\n' "$types" | grep -vE '^(test|docs|chore|style|ci)$' || true)"
  [ -n "$main_types" ] || main_types="$types"
  type="$(printf '%s\n' "$main_types" | awk 'NF { c[$1]++; if (!($1 in o)) o[$1] = NR } END { best = ""; for (t in c) if (best == "" || c[t] > c[best] || (c[t] == c[best] && o[t] < o[best])) best = t; print best }')"
  [ -n "$type" ] || type="feat"
  issue_title=""
  if [ -s "$scratch/linear/issue.md" ]; then
    issue_title="$(head -1 "$scratch/linear/issue.md" | sed -E 's/^#+[[:space:]]*//; s/^[A-Z]+-?[0-9]+[[:space:]]*(—|-|:)[[:space:]]*//')"
  elif [ -s "$scratch/spec.md" ]; then
    issue_title="$({ grep -m1 -E '^#+ ' "$scratch/spec.md" || true; } | sed -E 's/^#+[[:space:]]*//; s/^[A-Z]+-?[0-9]+[[:space:]]*(—|-|:)[[:space:]]*//')"
  fi
  [ -n "$issue_title" ] || issue_title="$(printf '%s\n' "$subjects" | head -1 | sed -E 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//')"
  title="$type: $issue_title ($task)"
fi

body_file="$(mktemp)"
{
  printf '## Summary\n\n'
  if [ -n "$summary" ] && [ -s "$summary" ]; then
    cat "$summary"; printf '\n'
  else
    printf '%s\n' "$subjects" | sed 's/^/- /'
    printf '\n'
  fi
  if [ -f "$scratch/phase-status.md" ]; then
    printf '## Quality report\n\n| Phase | Gate | Critical | High | Medium | Low |\n|---|---|---|---|---|---|\n'
    bash "$HOOK_DIR/pipeline.sh" rows "$scratch" 2>/dev/null | awk -F'|' '
      { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $6)
        if ($2 != "" && $2 != "Phase" && $2 !~ /^-+$/) printf "| %s | %s | %s | %s | %s | %s |\n", $2, toupper($6), $7+0, $8+0, $9+0, $10+0 }'
    printf '\n'
  fi
  if [ -s "$scratch/graph-decisions.md" ]; then
    printf '## Gate decisions (unattended)\n\n'; cat "$scratch/graph-decisions.md"; printf '\n'
  fi
  printf 'Closes %s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' "$task"
} > "$body_file"

# --- open the PR ------------------------------------------------------------------------
pr_url="$("$GH" pr create --base "$pr_base" --head "$branch" --title "$title" --body-file "$body_file" 2>/dev/null | tail -1)" || pr_url=""
rm -f "$body_file"
if [ -z "$pr_url" ]; then
  # A PR may already exist for this branch (a re-run after a conflict): reuse it.
  pr_url="$("$GH" pr view "$branch" --json url --jq .url 2>/dev/null || true)"
fi
[ -n "$pr_url" ] || { echo "pr-land.sh: gh pr create failed and no PR exists for $branch" >&2; exit 1; }
number="${pr_url##*/}"

# --- graph node: arm the forge's own auto-merge ------------------------------------------
automerge="skipped"
if [ "$keep_context" = "yes" ]; then
  if "$GH" pr merge --auto --squash "$branch" >/dev/null 2>&1; then automerge="armed"; else automerge="failed"; fi
fi

# --- Linear: attachment, comment, completed ------------------------------------------------
linear="skipped"
if [ "$storage" = "linear" ]; then
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    linear="done"
    bash "$HOOK_DIR/linear.sh" attach "$task" "$pr_url" --title "PR #$number" >/dev/null 2>&1 || linear="partial"
    note="$(mktemp)"
    { printf 'PR aberto: %s\n\n' "$pr_url"; printf '%s\n' "$subjects" | sed 's/^/- /'; } > "$note"
    bash "$HOOK_DIR/linear.sh" comment "$task" --body-file "$note" >/dev/null 2>&1 || linear="partial"
    rm -f "$note"
    done_name="$({ grep -m1 -E '^- Done Status:' "$config" 2>/dev/null || true; } | sed -E 's/^- Done Status:[[:space:]]*//')"
    [ "$done_name" = "not configured" ] && done_name=""
    bash "$HOOK_DIR/linear.sh" transition "$task" completed ${done_name:+--prefer "$done_name"} >/dev/null 2>&1 || linear="partial"
  else
    linear="mcp-needed"
  fi
fi

# --- finalize ----------------------------------------------------------------------------------
fin_args=()
[ "$keep_context" = "yes" ] && fin_args+=(--keep-context)
fin_out="$(bash "$HOOK_DIR/pr-finalize.sh" "$task" ${fin_args[@]+"${fin_args[@]}"} 2>/dev/null || true)"
context="$(field "$fin_out" context)"

line="result=landed pr=$pr_url number=$number branch=$branch automerge=$automerge linear=$linear context=${context:-unknown}"
[ -d "$scratch" ] && printf '%s\n' "$line" > "$scratch/pr-land.txt"
printf '%s\n' "$line"
