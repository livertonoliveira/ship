#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: test-exec.sh <scratch-dir> [--config <path>]" >&2
}

field_from() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  grep -m1 -E "^- $key:" "$file" 2>/dev/null | sed -E "s/^- $key:[[:space:]]*//" || true
}

is_resolved() {
  local v="$1"
  [ -n "$v" ] && [ "$v" != "unknown" ]
}

resolve_runner() {
  local scratch="$1" config="$2"
  RUNNER="$(field_from "$scratch/stack.md" 'Test runner')"
  PKG="$(field_from "$scratch/stack.md" 'Package manager')"

  if ! is_resolved "$RUNNER"; then
    RUNNER="$(field_from "$config" 'Test runner')"
    PKG="$(field_from "$config" 'Package manager')"
  fi
}

build_test_command() {
  local runner="$1" pkg="$2"
  CMD_WORDS=()
  CMD_USES_PKG_SCRIPT=0
  case "$runner" in
    jest|vitest|mocha|ava)
      if is_resolved "$pkg"; then
        CMD_WORDS=("$pkg" test)
        CMD_USES_PKG_SCRIPT=1
      else
        CMD_WORDS=(npx "$runner")
      fi
      ;;
    "node --test"|"node:test")
      CMD_WORDS=(node --test)
      ;;
    pytest)
      CMD_WORDS=(pytest)
      ;;
    *)
      read -r -a CMD_WORDS <<< "$runner"
      ;;
  esac
}

collect_test_files() {
  local generated="$1"
  TEST_FILES=()
  [ -f "$generated" ] || return 0
  grep -q '^- ' "$generated" 2>/dev/null || return 0
  while IFS= read -r line; do
    TEST_FILES+=("$line")
  done < <(grep '^- ' "$generated" | sed -E 's/^- ([^ ]+) \([a-zA-Z0-9_-]+\)$/\1/')
}

run_suite() {
  local out
  out="$(mktemp)"
  local exit_code=0
  set +e
  "$@" > "$out" 2>&1
  exit_code=$?
  set -e
  RUN_OUTPUT_FILE="$out"
  RUN_EXIT_CODE="$exit_code"
}

parse_failed_files() {
  local out="$1"
  FAILED_FILES="$( {
    awk '
      /^FAIL / { cur = $2 }
      /^PASS / { cur = "" }
      cur != "" && /(✕|✗|×)/ { print cur }
    ' "$out" || true
    grep "location: " "$out" 2>/dev/null | sed -E "s/.*location: '([^:]+):[0-9]+:[0-9]+'.*/\1/" || true
    grep -E '^FAILED ' "$out" 2>/dev/null | sed -E 's/^FAILED ([^:]+)::.*/\1/' || true
  } | sed "s#^$(pwd -P)/##" | sort )"
}

write_reports() {
  local scratch="$1" failed_files="$2" exit_code="$3"

  {
    printf '# Test Failures\n'
    if [ -n "$failed_files" ]; then
      printf '\n'
      printf '%s\n' "$failed_files" | uniq -c | while read -r count file; do
        if [ "$count" -eq 1 ]; then
          printf -- '- %s (1 failure)\n' "$file"
        else
          printf -- '- %s (%s failures)\n' "$file" "$count"
        fi
      done
    fi
  } > "$scratch/test-failures.md"

  local gate="pass"
  [ "$exit_code" -ne 0 ] && gate="fail"

  local ts run_placeholder
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_placeholder='#<RUN>'
  printf '| test | %s | %s | - | %s | 0 | 0 | 0 | 0 | |\n' "$run_placeholder" "$ts" "$gate" > "$scratch/phase-status-test.md"
}

main() {
  local scratch="" config="ship/config.md"

  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$scratch" ]; then
    usage
    exit 1
  fi

  resolve_runner "$scratch" "$config"
  if ! is_resolved "$RUNNER"; then
    echo "test command not found: $config" >&2
    exit 2
  fi

  build_test_command "$RUNNER" "$PKG"

  collect_test_files "$scratch/generated-tests.md"
  if [ "${#TEST_FILES[@]}" -gt 0 ]; then
    if [ "$CMD_USES_PKG_SCRIPT" -eq 1 ] && [ "$PKG" = "npm" ]; then
      CMD_WORDS+=(--)
    fi
    CMD_WORDS+=("${TEST_FILES[@]}")
  fi

  run_suite "${CMD_WORDS[@]}"
  parse_failed_files "$RUN_OUTPUT_FILE"
  rm -f "$RUN_OUTPUT_FILE"

  if [ -z "$FAILED_FILES" ] && [ "$RUN_EXIT_CODE" -ne 0 ]; then
    FAILED_FILES="(unparsed)"
  fi

  write_reports "$scratch" "$FAILED_FILES" "$RUN_EXIT_CODE"

  [ "$RUN_EXIT_CODE" -eq 0 ] && exit 0
  exit 1
}

main "$@"
