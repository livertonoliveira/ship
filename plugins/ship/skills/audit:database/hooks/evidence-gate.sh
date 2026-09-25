#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: evidence-gate.sh [<touched-files-file>]" >&2
}

is_test_file() {
  case "$1" in
    *.test.*|*.spec.*|*/__tests__/*|*/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

stem_of() {
  local p="$1" base dir
  base="${p##*/}"
  if [ "$base" = "$p" ]; then
    dir="."
  else
    dir="${p%/*}"
  fi
  local IFS=/ seg segs=() out=()
  read -ra segs <<< "$dir"
  for seg in "${segs[@]+"${segs[@]}"}"; do
    case "$seg" in
      tests|__tests__) break ;;
      *) out+=("$seg") ;;
    esac
  done
  dir="$(IFS=/; echo "${out[*]+"${out[*]}"}")"
  [ -z "$dir" ] && dir="."
  base="${base%%.test.*}"
  base="${base%%.spec.*}"
  base="${base%.*}"
  printf '%s/%s' "$dir" "$base"
}

json_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    item="${item//\\/\\\\}"
    item="${item//\"/\\\"}"
    printf '"%s"' "$item"
  done
  printf ']'
}

main() {
  local input_file="${1:-}"
  local touched=()

  if [ -n "$input_file" ]; then
    if [ ! -f "$input_file" ]; then
      echo "evidence-gate.sh: touched files file not found: $input_file" >&2
      exit 1
    fi
    while IFS= read -r f; do
      [ -n "$f" ] && touched+=("$f")
    done < "$input_file"
  else
    while IFS= read -r f; do
      [ -n "$f" ] && touched+=("$f")
    done
  fi

  local repo_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && repo_files+=("$f")
  done < <(git ls-files 2>/dev/null || true)

  local test_files=()
  local f
  for f in "${repo_files[@]+"${repo_files[@]}"}"; do
    if is_test_file "$f"; then
      test_files+=("$f")
    fi
  done

  local test_stems=$'\n'
  local tf
  for tf in "${test_files[@]+"${test_files[@]}"}"; do
    test_stems="${test_stems}$(stem_of "$tf")"$'\n'
  done

  local tested=()
  local untested=()

  for f in "${touched[@]+"${touched[@]}"}"; do
    if is_test_file "$f"; then
      continue
    fi

    local stem
    stem="$(stem_of "$f")"

    case "$test_stems" in
      *$'\n'"$stem"$'\n'*)
        tested+=("$f")
        ;;
      *)
        untested+=("$f")
        ;;
    esac
  done

  local tested_json untested_json
  tested_json="$(json_array "${tested[@]+"${tested[@]}"}")"
  untested_json="$(json_array "${untested[@]+"${untested[@]}"}")"

  printf '{"tested":%s,"untested":%s,"total":%d}\n' "$tested_json" "$untested_json" "${#touched[@]}"
  exit 0
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

main "$@"
