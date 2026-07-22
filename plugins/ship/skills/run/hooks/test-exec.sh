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
  # "none" is the config schema's explicit "not applicable" marker (see
  # ship:init template) — treat it the same as absent, never run it as a command.
  [ -n "$v" ] && [ "$v" != "unknown" ] && [ "$v" != "none" ]
}

resolve_runner() {
  local scratch="$1" config="$2"
  RUNNER="$(field_from "$scratch/stack.md" 'Test Framework')"
  PKG="$(field_from "$scratch/stack.md" 'Package Manager')"

  if ! is_resolved "$RUNNER"; then
    RUNNER="$(field_from "$config" 'Test Framework')"
    PKG="$(field_from "$config" 'Package Manager')"
  fi
}

pkg_script_exists() {
  local script="$1"
  [ -f package.json ] || return 1
  sed -n '/"scripts"[[:space:]]*:/,/}/p' package.json | grep -qE "\"${script}\"[[:space:]]*:"
}

resolve_static_checks() {
  local scratch="$1" config="$2"
  local runner="npm"
  is_resolved "$PKG" && runner="$PKG"

  TYPECHECK_CMD="$(field_from "$scratch/stack.md" 'Typecheck')"
  is_resolved "$TYPECHECK_CMD" || TYPECHECK_CMD="$(field_from "$config" 'Typecheck')"
  if ! is_resolved "$TYPECHECK_CMD"; then
    if pkg_script_exists typecheck; then
      TYPECHECK_CMD="$runner run typecheck"
    elif pkg_script_exists type-check; then
      TYPECHECK_CMD="$runner run type-check"
    fi
  fi

  LINT_CMD="$(field_from "$scratch/stack.md" 'Lint')"
  is_resolved "$LINT_CMD" || LINT_CMD="$(field_from "$config" 'Lint')"
  if ! is_resolved "$LINT_CMD" && pkg_script_exists lint; then
    LINT_CMD="$runner run lint"
  fi
}

start_static_check() {
  # Launches a static check in the background so typecheck and lint run
  # concurrently (they are independent). Sets STARTED_OUT + STARTED_PID; the
  # caller `wait`s on the PID to collect the real exit code.
  local cmd="$1"
  STARTED_OUT="$(mktemp)"
  ( bash -c "$cmd" > "$STARTED_OUT" 2>&1 ) &
  STARTED_PID=$!
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
      function flush() { if (cur != "" && marks == 0) print cur }
      /^FAIL / { flush(); cur = $2; marks = 0 }
      /^PASS / { flush(); cur = ""; marks = 0 }
      cur != "" && /(✕|✗|×)/ { print cur; marks++ }
      END { flush() }
    ' "$out" || true
    grep "location: " "$out" 2>/dev/null | sed -E "s/.*location: '([^:]+):[0-9]+:[0-9]+'.*/\1/" || true
    grep -E '^FAILED ' "$out" 2>/dev/null | sed -E 's/^FAILED ([^:]+)::.*/\1/' || true
  } | sed "s#^$(pwd -P)/##" | sort )"
}

write_reports() {
  local scratch="$1" failed_files="$2" exit_code="$3"

  {
    printf '# Test Failures\n'
    if [ "$TYPECHECK_EXIT" -gt 0 ]; then
      printf '\n## Typecheck failed (`%s`)\n\n```\n' "$TYPECHECK_CMD"
      tail -60 "$TYPECHECK_OUT"
      printf '```\n'
      if [ "$SUITE_SKIPPED" -eq 1 ]; then
        printf '\nTest suite not run: fix the typecheck errors first.\n'
      fi
    fi
    if [ "$LINT_EXIT" -gt 0 ]; then
      printf '\n## Lint failed (`%s`)\n\n```\n' "$LINT_CMD"
      tail -60 "$LINT_OUT"
      printf '```\n'
    fi
    if [ -n "$failed_files" ]; then
      printf '\n'
      printf '%s\n' "$failed_files" | uniq -c | while read -r count file; do
        if [ "$count" -eq 1 ]; then
          printf -- '- %s (1 failure)\n' "$file"
        else
          printf -- '- %s (%s failures)\n' "$file" "$count"
        fi
      done
    elif [ "$SUITE_SKIPPED" -eq 0 ] && [ "$RUN_EXIT_CODE" -ne 0 ]; then
      # Suite exited non-zero but no failing file could be parsed (e.g. Jest
      # "Test suite failed to run" with no per-test markers). Embed the raw tail
      # so the fix agent gets the actual error instead of a contentless marker.
      printf '\n## Test suite failed (could not parse failing files)\n\n```\n'
      [ -n "$RUN_OUTPUT_FILE" ] && [ -f "$RUN_OUTPUT_FILE" ] && tail -80 "$RUN_OUTPUT_FILE"
      printf '```\n'
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

  TYPECHECK_CMD=""
  LINT_CMD=""
  TYPECHECK_EXIT=0
  LINT_EXIT=0
  TYPECHECK_OUT=""
  LINT_OUT=""
  SUITE_SKIPPED=0
  RUN_OUTPUT_FILE=""
  RUN_EXIT_CODE=0
  resolve_static_checks "$scratch" "$config"

  local tc_pid="" lint_pid=""
  if is_resolved "$TYPECHECK_CMD"; then
    start_static_check "$TYPECHECK_CMD"
    TYPECHECK_OUT="$STARTED_OUT"
    tc_pid="$STARTED_PID"
  fi
  if is_resolved "$LINT_CMD"; then
    start_static_check "$LINT_CMD"
    LINT_OUT="$STARTED_OUT"
    lint_pid="$STARTED_PID"
  fi
  if [ -n "$tc_pid" ]; then
    set +e; wait "$tc_pid"; TYPECHECK_EXIT=$?; set -e
    echo "typecheck ($TYPECHECK_CMD): $([ "$TYPECHECK_EXIT" -eq 0 ] && echo pass || echo fail)"
  fi
  if [ -n "$lint_pid" ]; then
    set +e; wait "$lint_pid"; LINT_EXIT=$?; set -e
    echo "lint ($LINT_CMD): $([ "$LINT_EXIT" -eq 0 ] && echo pass || echo fail)"
  fi

  collect_test_files "$scratch/generated-tests.md"
  if [ "${#TEST_FILES[@]}" -gt 0 ]; then
    if [ "$CMD_USES_PKG_SCRIPT" -eq 1 ] && [ "$PKG" = "npm" ]; then
      CMD_WORDS+=(--)
    fi
    CMD_WORDS+=("${TEST_FILES[@]}")
  fi

  if [ "$TYPECHECK_EXIT" -gt 0 ]; then
    SUITE_SKIPPED=1
    RUN_EXIT_CODE=1
    FAILED_FILES=""
  else
    run_suite "${CMD_WORDS[@]}"
    parse_failed_files "$RUN_OUTPUT_FILE"
  fi

  local overall=0
  { [ "$RUN_EXIT_CODE" -ne 0 ] || [ "$TYPECHECK_EXIT" -gt 0 ] || [ "$LINT_EXIT" -gt 0 ]; } && overall=1

  write_reports "$scratch" "$FAILED_FILES" "$overall"

  [ -n "$RUN_OUTPUT_FILE" ] && rm -f "$RUN_OUTPUT_FILE"
  [ -n "$TYPECHECK_OUT" ] && rm -f "$TYPECHECK_OUT"
  [ -n "$LINT_OUT" ] && rm -f "$LINT_OUT"

  exit "$overall"
}

main "$@"
