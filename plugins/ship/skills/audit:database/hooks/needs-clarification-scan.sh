#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: needs-clarification-scan.sh <file|dir>" >&2
}

target_files() {
  local target="$1"
  if [ -d "$target" ]; then
    find "$target" -type f -name '*.md' -not -path '*/.git/*' | sort
  elif [ -f "$target" ]; then
    printf '%s\n' "$target"
  fi
}

is_high_impact() {
  local category="$1"
  case "$category" in
    functional-scope|data-model) return 0 ;;
    *) return 1 ;;
  esac
}

markers_in_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -oE '\[NEEDS CLARIFICATION:[^]]*\]' "$f" 2>/dev/null || true
}

marker_category() {
  local marker="$1"
  printf '%s' "$marker" \
    | sed -E 's/^\[NEEDS CLARIFICATION:[[:space:]]*//' \
    | awk -F':' '{print $1}' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

print_markers() {
  local label="$1"; shift
  echo "$label"
  local entry entry_category entry_marker entry_file
  for entry in "$@"; do
    IFS='|' read -r entry_category entry_marker entry_file <<< "$entry"
    echo "  [$entry_category] $entry_marker ($entry_file)"
  done
}

main() {
  if [ $# -ne 1 ] || [ -z "$1" ]; then
    usage
    exit 1
  fi

  local target="$1"

  if [ ! -e "$target" ]; then
    usage
    exit 1
  fi

  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(target_files "$target")

  local high_markers=()
  local low_markers=()

  local f marker category
  for f in "${files[@]+"${files[@]}"}"; do
    while IFS= read -r marker; do
      [ -n "$marker" ] || continue
      category="$(marker_category "$marker")"
      if is_high_impact "$category"; then
        high_markers+=("$category|$marker|$f")
      else
        low_markers+=("$category|$marker|$f")
      fi
    done < <(markers_in_file "$f")
  done

  if [ "${#high_markers[@]}" -eq 0 ] && [ "${#low_markers[@]}" -eq 0 ]; then
    echo "NEEDS CLARIFICATION scan — clean."
    exit 0
  fi

  [ "${#high_markers[@]}" -gt 0 ] && print_markers "High-impact clarifications (blocking):" "${high_markers[@]}"
  [ "${#low_markers[@]}" -gt 0 ] && print_markers "Low-impact clarifications (warning):" "${low_markers[@]}"

  if [ "${#high_markers[@]}" -gt 0 ]; then
    exit 2
  fi

  exit 1
}

main "$@"
