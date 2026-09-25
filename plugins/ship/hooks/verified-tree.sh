#!/usr/bin/env bash

# verified-tree.sh record <scratch-dir> | check <scratch-dir>
#
# /ship:pr re-ran typecheck, lint and the suite on the very tree the pipeline's
# last test-exec had just passed — a median 48s (p90 177s) per node spent
# re-proving a result that was already on disk. `record` stores the tree hash of
# the working tree (tracked + untracked, ignored files and the scratch dir
# excluded) together with whether that tree was green; `check` prints
# verified_tree=yes only when the current tree is byte-identical to a recorded
# green one. Commits do not change a tree, so the PR's own atomic commits keep
# the proof; any edit, merge or conflict resolution breaks it and the checks run.
#
# Green means: the last test row passed (not skipped) and, when static checks
# ran, typecheck and lint both exited 0.

set -euo pipefail

usage() {
  echo "usage: verified-tree.sh record <scratch-dir> | check <scratch-dir>" >&2
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

is_green() {
  local scratch="$1" gate tc lint
  [ -f "$scratch/phase-status-test.md" ] || return 1
  gate="$(awk -F'|' 'NR == 1 { gsub(/ /, "", $6); print $6 }' "$scratch/phase-status-test.md")"
  [ "$gate" = "pass" ] || return 1
  if [ -f "$scratch/static-exits.txt" ]; then
    tc="$(grep -m1 '^typecheck=' "$scratch/static-exits.txt" | cut -d= -f2)"
    lint="$(grep -m1 '^lint=' "$scratch/static-exits.txt" | cut -d= -f2)"
    [ "${tc:-1}" = "0" ] && [ "${lint:-1}" = "0" ] || return 1
  fi
  return 0
}

main() {
  local verb="${1:-}" scratch="${2:-}"
  [ -n "$verb" ] && [ -n "$scratch" ] || { usage; exit 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "verified-tree.sh: not inside a git work tree" >&2; exit 1; }

  case "$verb" in
    record)
      mkdir -p "$scratch"
      if is_green "$scratch"; then
        local t
        t="$(tree_hash)" || { rm -f "$scratch/verified-tree.txt"; exit 0; }
        printf '%s\n' "$t" > "$scratch/verified-tree.txt"
        printf 'recorded=%s\n' "$t"
      else
        rm -f "$scratch/verified-tree.txt"
        printf 'recorded=none\n'
      fi
      ;;
    check)
      local want have
      want="$(head -1 "$scratch/verified-tree.txt" 2>/dev/null || true)"
      if [ -n "$want" ] && have="$(tree_hash)" && [ "$have" = "$want" ]; then
        printf 'verified_tree=yes\n'
      else
        printf 'verified_tree=no\n'
      fi
      ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
