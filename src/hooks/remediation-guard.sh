#!/usr/bin/env bash

# remediation-guard.sh snapshot|check|restore <scratch-dir>
#
# A remediation fix can "resolve" a finding by restoring the task's files to the
# base: measured live, a review finding that the new hooks had no consumer yet
# (the spec deferred them to later tasks) was fixed by reverting both files, the
# confirmation pass agreed, the gate passed, and the node only failed at landing
# with nothing to commit — the develop work gone for good.
#
# `snapshot` stores the working tree (tracked + untracked, ignored files and the
# scratch dir excluded) as a tree object right before the fix is dispatched.
# `check`, once the fix returns, compares the tree to the run's base commit: when
# the change existed before the fix and the fix left no change at all, it puts
# the snapshot back and prints erased=yes. A fix that keeps any part of the
# change is not judged here.
#
# `restore` puts the snapshot back unconditionally — the pipeline calls it when
# the fix turned a check red that was green before it.
#
# Prints: erased=yes|no (check), restored=yes|no (restore)

set -euo pipefail

usage() {
  echo "usage: remediation-guard.sh snapshot|check|restore <scratch-dir>" >&2
}

tree_hash() {
  local idx src
  idx="$(mktemp)"
  src="$(git rev-parse --git-path index 2>/dev/null || true)"
  if [ -n "$src" ] && [ -f "$src" ]; then cp "$src" "$idx"; else rm -f "$idx"; fi
  GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1 || { rm -f "$idx"; return 1; }
  GIT_INDEX_FILE="$idx" git rm -r -q --cached --ignore-unmatch .context >/dev/null 2>&1 || true
  GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null
  rm -f "$idx"
}

restore_tree() {
  local tree="$1" idx
  idx="$(mktemp)"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree "$tree"
  GIT_INDEX_FILE="$idx" git checkout-index -a -f
  rm -f "$idx"
}

main() {
  local verb="${1:-}" scratch="${2:-}"
  [ -n "$verb" ] && [ -n "$scratch" ] || { usage; exit 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "remediation-guard.sh: not inside a git work tree" >&2; exit 1; }

  case "$verb" in
    snapshot)
      mkdir -p "$scratch"
      local t
      t="$(tree_hash)" || { rm -f "$scratch/remediation-pre-fix-tree.txt"; exit 0; }
      printf '%s\n' "$t" > "$scratch/remediation-pre-fix-tree.txt"
      ;;
    check)
      local pre base_sha base after
      pre="$(head -1 "$scratch/remediation-pre-fix-tree.txt" 2>/dev/null || true)"
      base_sha="$(head -1 "$scratch/pre-quality-snapshot.sha" 2>/dev/null || true)"
      if [ -z "$pre" ] || [ -z "$base_sha" ] \
        || ! base="$(git rev-parse --verify -q "$base_sha^{tree}")" \
        || ! after="$(tree_hash)" \
        || [ "$pre" = "$base" ] || [ "$after" != "$base" ]; then
        printf 'erased=no\n'
        exit 0
      fi
      restore_tree "$pre"
      printf 'restored=%s base=%s\n' "$pre" "$base_sha" > "$scratch/remediation-erased.txt"
      printf 'erased=yes\n'
      ;;
    restore)
      # Puts the snapshot back whatever the fix did: files the fix added are
      # removed, everything else returns to its pre-fix content.
      local pre after f
      pre="$(head -1 "$scratch/remediation-pre-fix-tree.txt" 2>/dev/null || true)"
      [ -n "$pre" ] && git cat-file -e "$pre^{tree}" 2>/dev/null || { printf 'restored=no\n'; exit 0; }
      after="$(tree_hash)" || { printf 'restored=no\n'; exit 0; }
      git diff --name-only --no-renames --diff-filter=A "$pre" "$after" | while IFS= read -r f; do
        rm -f -- "$f"
      done
      restore_tree "$pre"
      printf 'restored=yes\n'
      ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
