#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: capture-diff.sh <output-file> [--base <ref>] [--prefer <existing>] | --assert-only <file>" >&2
  echo "  --prefer <existing>  reuse <existing> if it is a non-empty valid unified diff; else capture fresh" >&2
}

assert_valid_unified_diff() {
  local out="$1"

  if [ -s "$out" ] && ! grep -q '^diff --git ' "$out"; then
    echo "$out is non-empty but has no 'diff --git' header — not a valid unified diff. Re-capture before proceeding." >&2
    : > "$out"
    return 1
  fi

  return 0
}

# <ref> alone is not proof it names real history — a freshly bootstrapped repo
# with no remote (or one whose default branch was never pushed) has no
# `origin/main` to merge-base against, and `git merge-base` failing under
# `set -e` used to abort the whole pipeline on a bare "fatal: Not a valid
# object name" with no indication which ref or what to do about it.
resolve_base_ref() {
  local ref="$1" local_name
  if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    printf '%s' "$ref"
    return 0
  fi
  local_name="${ref#*/}"
  if [ "$local_name" != "$ref" ] && git rev-parse --verify --quiet "$local_name^{commit}" >/dev/null; then
    echo "capture-diff.sh: $ref not found — using local $local_name instead" >&2
    printf '%s' "$local_name"
    return 0
  fi
  echo "capture-diff.sh: $ref not found and no local $local_name — diffing against the repo's root commit" >&2
  git rev-list --max-parents=0 HEAD | tail -1
}

capture_diff() {
  local out="$1" base_ref="$2" base resolved

  mkdir -p "$(dirname "$out")"
  resolved="$(resolve_base_ref "$base_ref")"
  base="$(git merge-base "$resolved" HEAD)"
  git add -A -N >/dev/null 2>&1 || true
  git diff "$base" > "$out"
}

main() {
  local output_file="" base_ref="origin/main" assert_only_file="" prefer_file="" positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] || { usage; exit 1; }
        base_ref="$2"
        shift 2
        ;;
      --assert-only)
        [ $# -ge 2 ] || { usage; exit 1; }
        assert_only_file="$2"
        shift 2
        ;;
      --prefer)
        [ $# -ge 2 ] || { usage; exit 1; }
        prefer_file="$2"
        shift 2
        ;;
      --*)
        usage
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ -n "$assert_only_file" ]; then
    [ "${#positional[@]}" -eq 0 ] || { usage; exit 1; }
    assert_valid_unified_diff "$assert_only_file"
    exit $?
  fi

  [ "${#positional[@]}" -eq 1 ] || { usage; exit 1; }
  output_file="${positional[0]}"

  # Reuse an already-captured diff (e.g. the pipeline's scratch diff.md) when it
  # is present and valid, so standalone phase skills don't re-run git.
  if [ -n "$prefer_file" ] && [ -s "$prefer_file" ] && grep -q '^diff --git ' "$prefer_file"; then
    if [ "$prefer_file" != "$output_file" ]; then
      mkdir -p "$(dirname "$output_file")"
      cp "$prefer_file" "$output_file"
    fi
    exit 0
  fi

  capture_diff "$output_file" "$base_ref"
  assert_valid_unified_diff "$output_file"
}

main "$@"
