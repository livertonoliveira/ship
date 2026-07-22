#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: status-consolidate.sh <run-number> <scratch-file>..." >&2
  exit 1
}

is_table_line() {
  local line="$1"
  local trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [[ "$trimmed" == \|*\| ]]
}

consolidate() {
  local run="$1"
  shift
  local file

  for file in "$@"; do
    if [ ! -f "$file" ]; then
      echo "status-consolidate.sh: scratch file not found: $file" >&2
      exit 1
    fi
  done

  for file in "$@"; do
    while IFS= read -r line || [ -n "$line" ]; do
      is_table_line "$line" || continue
      printf '%s\n' "${line/\#<RUN>/#$run}"
    done < "$file"
  done
}

[ $# -ge 2 ] || usage

consolidate "$@"
