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

capture_diff() {
  local out="$1" base_ref="$2" base

  mkdir -p "$(dirname "$out")"
  base="$(git merge-base "$base_ref" HEAD)"
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
