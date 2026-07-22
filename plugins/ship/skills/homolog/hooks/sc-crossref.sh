#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: sc-crossref.sh --index <file> --issues <dir|files...>" >&2
}

index_pairs() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -E '^-?[[:space:]]*SC-[0-9]+[[:space:]]*(→|->)[[:space:]]*AC-[0-9]+' "$f" 2>/dev/null \
    | sed -E 's/^-?[[:space:]]*//' \
    | sed -E 's/→/->/' \
    | awk -F'->' '{
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1);
        gsub(/^[[:space:]]+/,"",$2);
        split($2,r,/[[:space:]]*·/);
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",r[1]);
        print $1"|"r[1]
      }' || true
}

issue_files() {
  local target="$1"
  shift
  if [ -d "$target" ]; then
    find "$target" -type f -name '*.md' | sort
  elif [ -f "$target" ]; then
    printf '%s\n' "$target"
  fi
  if [ $# -gt 0 ]; then
    printf '%s\n' "$@"
  fi
}

issue_tags() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -oE '@SC-[0-9]+[[:space:]]+@AC-[0-9]+[[:space:]]+@[a-zA-Z]+' "$f" 2>/dev/null \
    | awk '{
        sc=$1; ac=$2;
        sub(/^@/,"",sc); sub(/^@/,"",ac);
        print sc"|"ac
      }' || true
}

ac_for_sc() {
  local sc="$1" pairs="$2" line
  while IFS='|' read -r line_sc line_ac; do
    [ "$line_sc" = "$sc" ] || continue
    printf '%s' "$line_ac"
    return 0
  done <<< "$pairs"
  return 1
}

main() {
  local index_file="" issues_target="" issues_extra=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --index)
        [ $# -ge 2 ] || { usage; exit 1; }
        index_file="$2"
        shift 2
        ;;
      --issues)
        [ $# -ge 2 ] || { usage; exit 1; }
        shift
        issues_target="$1"
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --*) break ;;
            *)
              issues_extra=("${issues_extra[@]+"${issues_extra[@]}"}" "$1")
              shift
              ;;
          esac
        done
        ;;
      --*)
        usage
        exit 1
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  done

  if [ -z "$index_file" ] || [ -z "$issues_target" ]; then
    usage
    exit 1
  fi

  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(issue_files "$issues_target" "${issues_extra[@]+"${issues_extra[@]}"}")

  local index_data
  index_data="$(index_pairs "$index_file")"

  local index_scs=()
  local sc ac
  if [ -n "$index_data" ]; then
    while IFS='|' read -r sc ac; do
      [ -n "$sc" ] || continue
      index_scs+=("$sc")
    done <<< "$index_data"
  fi

  local occurrences=()
  local violations=()

  local f
  for f in "${files[@]+"${files[@]}"}"; do
    grep -q '^## Scenarios' "$f" 2>/dev/null || continue
    local tags
    tags="$(issue_tags "$f")"
    [ -n "$tags" ] || continue
    while IFS='|' read -r sc ac; do
      [ -n "$sc" ] || continue

      local prior_count=0
      local entry
      for entry in "${occurrences[@]+"${occurrences[@]}"}"; do
        case "$entry" in
          "$sc|"*)
            prior_count=$((prior_count + 1))
            ;;
        esac
      done
      occurrences+=("$sc|$ac|$f")

      local idx_ac=""
      local in_index=1
      idx_ac="$(ac_for_sc "$sc" "$index_data")" && in_index=0

      if [ "$in_index" -ne 0 ]; then
        violations+=("orphan: $sc [issue: $f]")
        continue
      fi

      if [ "$prior_count" -eq 0 ] && [ "$idx_ac" != "$ac" ]; then
        violations+=("mismatch: $sc [issue: $f]")
      fi

      if [ "$prior_count" -ge 1 ]; then
        violations+=("duplicate: $sc [issue: $f]")
      fi
    done <<< "$tags"
  done

  for sc in "${index_scs[@]+"${index_scs[@]}"}"; do
    local found=1
    local entry
    for entry in "${occurrences[@]+"${occurrences[@]}"}"; do
      case "$entry" in
        "$sc|"*) found=0; break ;;
      esac
    done
    if [ "$found" -ne 0 ]; then
      violations+=("missing: $sc [issue: -]")
    fi
  done

  if [ "${#violations[@]}" -eq 0 ]; then
    echo "SC cross-reference — clean."
    exit 0
  fi

  printf '%s\n' "${violations[@]}"
  exit 1
}

main "$@"
