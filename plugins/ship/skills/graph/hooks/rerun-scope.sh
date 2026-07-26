#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: rerun-scope.sh [<changed-files-file>] [--config <path>]" >&2
  echo "  reads changed files (one path per line) from the given file," >&2
  echo "  or from stdin if no argument is given" >&2
  echo "  --config: when Gate Behavior -> on_fail_rerun is 'all', force every phase" >&2
  echo "  to rerun=true and skip scope mapping entirely (unless the fix was empty)" >&2
}

on_fail_rerun_mode() {
  local config="$1"
  [ -f "$config" ] || { printf 'surgical'; return; }
  local v
  v="$(grep -m1 -E '^-[[:space:]]*on_fail_rerun:' "$config" 2>/dev/null | sed -E 's/^-[[:space:]]*on_fail_rerun:[[:space:]]*//' | awk '{print $1}' || true)"
  printf '%s' "${v:-surgical}"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

is_test_file() {
  local f="$1"
  case "$f" in
    *.test.*|*.spec.*|*__tests__/*|*/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

matches_perf_scope() {
  local f="$1"
  case "$f" in
    src/*|lib/*)
      if is_test_file "$f"; then
        return 1
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

is_out_of_scope() {
  local f="$1"
  case "$f" in
    src/*|lib/*) return 1 ;;
    *) return 0 ;;
  esac
}

read_changed_files() {
  local input="$1"
  local line

  if [ -n "$input" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line"
    done < "$input"
  else
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line"
    done
  fi
}

emit_phase() {
  local name="$1" rerun="$2" reason="$3"
  printf '"%s":{"rerun":%s,"reason":"%s"}' "$name" "$rerun" "$(json_escape "$reason")"
}

main() {
  local input="" config="" positional=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        case "$positional" in
          0) input="$1" ;;
          *) usage; exit 1 ;;
        esac
        positional=$((positional + 1))
        shift ;;
    esac
  done

  if [ -n "$input" ] && [ ! -f "$input" ]; then
    echo "rerun-scope.sh: input file not found: $input" >&2
    exit 1
  fi

  local files=()
  local line
  while IFS= read -r line; do
    files+=("$line")
  done < <(read_changed_files "$input")

  local empty="false"
  if [ "${#files[@]}" -eq 0 ]; then
    empty="true"
  fi

  local out_of_scope="false"
  local out_of_scope_file=""
  local perf_match="false"
  local perf_file=""

  local f
  for f in "${files[@]:-}"; do
    [ -n "$f" ] || continue
    if [ "$out_of_scope" = "false" ] && is_out_of_scope "$f"; then
      out_of_scope="true"
      out_of_scope_file="$f"
    fi
    if [ "$perf_match" = "false" ] && matches_perf_scope "$f"; then
      perf_match="true"
      perf_file="$f"
    fi
  done

  local perf_rerun perf_reason
  local security_rerun security_reason
  local review_rerun review_reason

  if [ "$empty" = "true" ]; then
    perf_rerun="false"; perf_reason="no changed files"
    security_rerun="false"; security_reason="no changed files"
    review_rerun="false"; review_reason="no changed files"
  else
    if [ "$perf_match" = "true" ]; then
      perf_rerun="true"
      perf_reason="matched by $perf_file"
    else
      perf_rerun="false"
      perf_reason="no changed files matched phase scope"
    fi

    security_rerun="true"
    security_reason="security scope is broad (full diff)"

    review_rerun="true"
    review_reason="review scope is broad (full diff)"

    if [ -n "$config" ] && [ "$(on_fail_rerun_mode "$config")" = "all" ]; then
      local all_reason="on_fail_rerun: all — scope mapping skipped, full re-run forced by config"
      perf_rerun="true"; perf_reason="$all_reason"
      security_rerun="true"; security_reason="$all_reason"
      review_rerun="true"; review_reason="$all_reason"
    fi
  fi

  printf '{"phases":{'
  emit_phase "perf" "$perf_rerun" "$perf_reason"
  printf ','
  emit_phase "security" "$security_rerun" "$security_reason"
  printf ','
  emit_phase "review" "$review_rerun" "$review_reason"
  printf '},"out_of_scope":%s,"empty":%s}\n' "$out_of_scope" "$empty"
}

main "$@"
