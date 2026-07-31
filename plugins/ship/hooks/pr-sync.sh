#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# pr-sync.sh — brings this branch up to date with its PR base, right before the
# push that opens the PR.
#
# Whoever is behind rebases; nobody else merges for them. The agent calling this
# is the one that just implemented the change, still holding its intent, its
# plan and its tests — so when the rebase stops on a conflict, the resolution
# happens there and then, in that context. The alternative Ship used to have was
# a coordinator merging every branch into a shared trunk and, on conflict,
# handing the wreck to a fresh agent whose only input was a failure log; on
# shared files (global styles, test utilities) that agent had to reconstruct
# intent by git archaeology, and reliably got it wrong.
#
# Prints result=clean|conflict|skipped-<why>, plus one `conflict:<path>` line
# per unmerged file. Never fatal: a conflict is a step of the work, not an error.
# ---------------------------------------------------------------------------

usage() {
  echo "usage: pr-sync.sh --remote <remote> --base <branch>" >&2
  echo "       pr-sync.sh --continue" >&2
  echo "  Rebases the current branch onto <remote>/<base> before the PR is opened." >&2
  echo "  Prints: result=clean|conflict|skipped-<why>  plus conflict:<path> lines" >&2
}

report_conflicts() {
  git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/conflict:/' || true
}

main() {
  local remote="" base="" cont=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --remote) remote="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --continue) cont=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  if [ "$cont" -eq 1 ]; then
    [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] \
      || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ] \
      || { printf 'result=skipped-no-rebase-in-progress\n'; exit 0; }
    git add -A >/dev/null 2>&1 || true
    # An empty patch is what a conflict resolved by taking the base's side looks
    # like; `--continue` refuses it and `--skip` is the documented answer.
    if git diff --cached --quiet 2>/dev/null; then
      GIT_EDITOR=true git rebase --skip >/dev/null 2>&1 || true
    else
      GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
    fi
    if [ -n "$(report_conflicts)" ]; then
      printf 'result=conflict\n'
      report_conflicts
      exit 0
    fi
    if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] \
      || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
      printf 'result=conflict\n'
      exit 0
    fi
    printf 'result=clean\n'
    exit 0
  fi

  [ -n "$base" ] || { usage; exit 1; }
  [ -n "$remote" ] || { printf 'result=skipped-no-remote\n'; exit 0; }

  # A rebase refuses to start over uncommitted work, and its refusal looks
  # exactly like a conflict from the outside. Naming the real cause keeps the
  # caller from "resolving" files that were never in conflict.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    printf 'result=skipped-dirty-tree\n'
    printf 'note=commit the working tree first — this branch was not synced\n'
    exit 0
  fi

  if ! git fetch -q "$remote" "$base" >/dev/null 2>&1; then
    printf 'result=skipped-fetch-failed\n'
    printf 'note=%s has no %s to sync against yet\n' "$remote" "$base"
    exit 0
  fi

  if git rebase FETCH_HEAD >/dev/null 2>&1; then
    printf 'result=clean\n'
    printf 'base=%s/%s\n' "$remote" "$base"
    exit 0
  fi

  printf 'result=conflict\n'
  printf 'base=%s/%s\n' "$remote" "$base"
  report_conflicts
  exit 0
}

main "$@"
