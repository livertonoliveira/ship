#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: worker-status-gate.sh <phase-status-file>" >&2
}

status_lines() {
  local f="$1"
  grep -E '^Status:' "$f" 2>/dev/null || true
}

status_value() {
  local line="$1"
  printf '%s' "$line" | sed -E 's/^Status:[[:space:]]*//'
}

validate_status() {
  local f="$1" lines line_count value

  lines="$(status_lines "$f")"
  line_count="$(printf '%s\n' "$lines" | grep -c . || true)"

  if [ "$line_count" -eq 0 ]; then
    echo "worker-status-gate: missing Status field in $f" >&2
    return 1
  fi

  if [ "$line_count" -gt 1 ]; then
    echo "worker-status-gate: conflicting multiple Status lines in $f" >&2
    return 1
  fi

  value="$(status_value "$lines")"

  if [ -z "$value" ]; then
    echo "worker-status-gate: empty Status value in $f" >&2
    return 1
  fi

  case "$value" in
    DONE|DONE_WITH_CONCERNS|NEEDS_CONTEXT|BLOCKED)
      return 0
      ;;
    *)
      echo "worker-status-gate: Status value out of enum — '$value' in $f (expected: DONE|DONE_WITH_CONCERNS|NEEDS_CONTEXT|BLOCKED)" >&2
      return 1
      ;;
  esac
}

main() {
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --*)
        echo "worker-status-gate: unknown flag: $1" >&2
        usage
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ "${#positional[@]}" -ne 1 ]; then
    echo "worker-status-gate: expected 1 argument, got ${#positional[@]}" >&2
    usage
    exit 1
  fi
  local status_file="${positional[0]}"

  if [ ! -f "$status_file" ]; then
    echo "worker-status-gate: status file not found: $status_file" >&2
    exit 1
  fi

  if validate_status "$status_file"; then
    echo "worker-status-gate: valid status"
    exit 0
  else
    exit 2
  fi
}

main "$@"
