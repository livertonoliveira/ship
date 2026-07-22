#!/usr/bin/env bash

set -euo pipefail

hash_or_absent() {
  local f="$1"
  git hash-object -- "$f" 2>/dev/null || printf 'absent'
}

cmd_snapshot() {
  local out="$1" base
  base="$(git merge-base origin/main HEAD)"
  git add -A -N >/dev/null 2>&1 || true

  {
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '%s %s\n' "$(hash_or_absent "$f")" "$f"
    done < <(git diff "$base" --name-only)
  } | sort > "$out"
}

cmd_diff() {
  local pre="$1" post="$2"

  if [ ! -f "$pre" ]; then
    echo "snapshot-files.sh diff: pre-snapshot file not found: $pre" >&2
    exit 1
  fi
  if [ ! -f "$post" ]; then
    echo "snapshot-files.sh diff: post-snapshot file not found: $post" >&2
    exit 1
  fi

  comm -13 <(sort "$pre") <(sort "$post") | awk '{print $2}' | sort -u
}

case "${1:-}" in
  snapshot)
    [ $# -eq 2 ] || { echo "usage: snapshot-files.sh snapshot <output-file>" >&2; exit 1; }
    cmd_snapshot "$2"
    ;;
  diff)
    [ $# -eq 3 ] || { echo "usage: snapshot-files.sh diff <pre-file> <post-file>" >&2; exit 1; }
    cmd_diff "$2" "$3"
    ;;
  *)
    echo "usage: snapshot-files.sh snapshot <output-file> | diff <pre-file> <post-file>" >&2
    exit 1
    ;;
esac
