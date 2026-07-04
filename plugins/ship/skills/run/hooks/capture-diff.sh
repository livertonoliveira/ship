#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: capture-diff.sh <output-file> [--base <ref>] | --assert-only <file>" >&2
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

  base="$(git merge-base "$base_ref" HEAD)"
  git add -A -N >/dev/null 2>&1 || true
  git diff "$base" > "$out"
}

main() {
  local output_file="" base_ref="origin/main" assert_only_file="" positional=()

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

  capture_diff "$output_file" "$base_ref"
  assert_valid_unified_diff "$output_file"
}

main "$@"
