#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: diff-classify.sh <diff-file> <output-file> [--config <path>]" >&2
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || printf '.'
}

changed_line_count() {
  local f="$1"
  grep -E '^[+-]' "$f" 2>/dev/null | grep -Ev '^(\+\+\+|---)' | wc -l | tr -d ' '
}

logical_files() {
  local f="$1"
  grep '^+++ b/' "$f" 2>/dev/null | sed 's|^+++ b/||' | grep -Ev '\.(md|json|lock|txt|ya?ml)$' | sort -u
}

logical_file_count() {
  local f="$1"
  logical_files "$f" | grep -c '.' || true
}

all_modified_files() {
  local f="$1"
  grep '^+++ b/' "$f" 2>/dev/null | sed 's|^+++ b/||' | sort -u
}

new_endpoint_count() {
  local f="$1"
  grep '^+' "$f" 2>/dev/null | grep -Ev '^\+\+\+' \
    | grep -E "route\(|app\.(get|post|put|patch|delete)\(|@(Get|Post|Put|Patch|Delete)\(" \
    | wc -l | tr -d ' '
}

sensitive_paths_from_config() {
  local cfg="$1" in_section=0 line stripped
  [ -f "$cfg" ] || return 1
  grep -q '^## Sensitive Paths' "$cfg" || return 1
  while IFS= read -r line; do
    if [ "$in_section" -eq 1 ]; then
      case "$line" in
        '## '*) break ;;
        '- '*)
          stripped="${line#- }"
          printf '%s\n' "$stripped"
          ;;
      esac
    fi
    case "$line" in
      '## Sensitive Paths') in_section=1 ;;
    esac
  done < "$cfg"
  return 0
}

sensitive_path_count() {
  local f="$1" cfg="$2" paths pattern joined=""
  if paths="$(sensitive_paths_from_config "$cfg")"; then
    if [ -z "$paths" ]; then
      printf '0'
      return 0
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -z "$joined" ]; then joined="$p"; else joined="$joined|$p"; fi
    done <<< "$paths"
    if [ -z "$joined" ]; then
      printf '0'
      return 0
    fi
    pattern="^($joined)"
  else
    pattern='^(auth/|payment/|query|migrations/)'
  fi
  all_modified_files "$f" | grep -cE "$pattern" || true
}

is_doc_config_only() {
  local f="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *.md|*.json|*.lock|*.txt|*.yml|*.yaml) ;;
      *) return 1 ;;
    esac
  done < <(all_modified_files "$f")
  return 0
}

classify() {
  local diff_file="$1" cfg="$2" lines logical_n endpoints sensitive_n reason class

  if [ ! -s "$diff_file" ]; then
    printf 'trivial\n'
    printf 'empty diff\n'
    return 0
  fi

  lines="$(changed_line_count "$diff_file")"
  logical_n="$(logical_file_count "$diff_file")"
  endpoints="$(new_endpoint_count "$diff_file")"
  sensitive_n="$(sensitive_path_count "$diff_file" "$cfg")"

  if is_doc_config_only "$diff_file" && [ "$sensitive_n" -eq 0 ] && [ "$lines" -lt 50 ]; then
    printf 'trivial\n'
    printf 'only doc/config files, %s lines, no sensitive paths\n' "$lines"
    return 0
  fi

  if [ "$lines" -gt 1000 ] || [ "$logical_n" -gt 10 ]; then
    if [ "$lines" -gt 1000 ]; then
      reason="$lines lines changed"
    else
      reason="$logical_n logical files"
    fi
    printf 'large\n'
    printf '%s\n' "$reason"
    return 0
  fi

  if [ "$lines" -lt 100 ] && [ "$logical_n" -le 1 ] && [ "$endpoints" -eq 0 ]; then
    printf 'minor\n'
    printf '%s lines, %s logical file, no new endpoints\n' "$lines" "$logical_n"
    return 0
  fi

  printf 'normal\n'
  printf 'default classification\n'
}

main() {
  local diff_file="" output_file="" cfg_arg="" positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        [ $# -ge 2 ] || { usage; exit 1; }
        cfg_arg="$2"
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

  [ "${#positional[@]}" -eq 2 ] || { usage; exit 1; }
  diff_file="${positional[0]}"
  output_file="${positional[1]}"

  if [ ! -f "$diff_file" ]; then
    echo "diff-classify.sh: diff file not found: $diff_file" >&2
    exit 1
  fi

  local root cfg
  root="$(repo_root)"
  if [ -n "$cfg_arg" ]; then
    cfg="$cfg_arg"
  else
    cfg="$root/ship/config.md"
  fi

  local result class reason
  result="$(classify "$diff_file" "$cfg")"
  class="$(printf '%s' "$result" | sed -n '1p')"
  reason="$(printf '%s' "$result" | sed -n '2p')"

  printf '%s\n' "$class" > "$output_file"
  printf '%s (%s)\n' "$class" "$reason"
}

main "$@"
