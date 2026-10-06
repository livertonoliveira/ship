#!/usr/bin/env bash

set -euo pipefail

hash_or_absent() {
  local f="$1"
  git hash-object -- "$f" 2>/dev/null || printf 'absent'
}

# `origin/main` is not proof it names real history — a repo with no remote, or
# whose default branch isn't literally "main", has no such ref and `git
# merge-base` fails under `set -e` with a bare "fatal: Not a valid object
# name" that gives no indication what to do about it. Same fallback chain as
# capture-diff.sh's resolve_base_ref: the ref itself, its local name, then the
# repo's root commit.
resolve_base_ref() {
  local ref="$1" local_name
  if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    printf '%s' "$ref"
    return 0
  fi
  local_name="${ref#*/}"
  if [ "$local_name" != "$ref" ] && git rev-parse --verify --quiet "$local_name^{commit}" >/dev/null; then
    echo "snapshot-files.sh: $ref not found — using local $local_name instead" >&2
    printf '%s' "$local_name"
    return 0
  fi
  echo "snapshot-files.sh: $ref not found and no local $local_name — snapshotting against the repo's root commit" >&2
  git rev-list --max-parents=0 HEAD | tail -1
}

cmd_snapshot() {
  local out="$1" base resolved
  resolved="$(resolve_base_ref origin/main)"
  base="$(git merge-base "$resolved" HEAD)"
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
