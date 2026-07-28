#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: test-exec.sh <scratch-dir> [--config <path>] [--static-only|--print-static]" >&2
  echo "  --print-static  resolve typecheck/lint and print them without running" >&2
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

# `- <path> (<layer>)` manifest rows, kept as "<layer><TAB><path>" lines. The
# layer used to be parsed off and thrown away, which is what let an e2e file
# reach a runner whose config cannot even see it.
collect_test_entries() {
  local generated="$1"
  TEST_ENTRIES=""
  [ -f "$generated" ] || return 0
  TEST_ENTRIES="$(awk '
    /^- / {
      if (match($0, /^- [^ ]+ \([a-zA-Z0-9_-]+\)$/)) {
        path = $2
        layer = $3
        gsub(/[()]/, "", layer)
        printf "%s\t%s\n", layer, path
      } else {
        sub(/^- /, "")
        if ($0 != "") printf "unknown\t%s\n", $1
      }
    }
  ' "$generated" || true)"
}

# A layer whose files only run under a dedicated package script — a separate
# config, a different testRegex — is invisible to the generic `test` script: the
# suite reports green having never loaded them. Prefer `test:<layer>` when the
# project defines it; fall back to the generic command otherwise.
layer_command_words() {
  local layer="$1"
  LAYER_CMD_WORDS=("${CMD_WORDS[@]}")
  LAYER_USES_PKG_SCRIPT="$CMD_USES_PKG_SCRIPT"
  case "$layer" in
    unit|integration|e2e) ;;
    *) return 0 ;;
  esac
  if is_resolved "$PKG" && pkg_script_exists "test:$layer"; then
    LAYER_CMD_WORDS=("$PKG" run "test:$layer")
    LAYER_USES_PKG_SCRIPT=1
  fi
}

# One run per layer, outputs concatenated so parse_failed_files and the report
# see every failure regardless of which runner produced it.
run_suites_by_layer() {
  if [ -z "$TEST_ENTRIES" ]; then
    run_suite "${CMD_WORDS[@]}"
    return 0
  fi
  local combined layers l p rc=0
  combined="$(mktemp)"
  layers="$(printf '%s\n' "$TEST_ENTRIES" | cut -f1 | sort -u)"
  for l in $layers; do
    layer_command_words "$l"
    local words=("${LAYER_CMD_WORDS[@]}")
    if [ "$LAYER_USES_PKG_SCRIPT" -eq 1 ] && [ "$PKG" = "npm" ]; then
      words+=(--)
    fi
    while IFS= read -r p; do
      [ -n "$p" ] && words+=("$p")
    done < <(printf '%s\n' "$TEST_ENTRIES" | awk -F'\t' -v L="$l" '$1==L{print $2}')
    run_suite "${words[@]}"
    cat "$RUN_OUTPUT_FILE" >> "$combined"
    rm -f "$RUN_OUTPUT_FILE"
    [ "$RUN_EXIT_CODE" -ne 0 ] && rc=1
  done
  RUN_OUTPUT_FILE="$combined"
  RUN_EXIT_CODE="$rc"
  return 0
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
    # The output files are absent when the exits were carried forward from the
    # earlier static run rather than produced here; static-failures.md already
    # holds that output, so only the consequence is reported.
    if [ "$TYPECHECK_EXIT" -gt 0 ]; then
      printf '\n## Typecheck failed (`%s`)\n' "$TYPECHECK_CMD"
      if [ -n "$TYPECHECK_OUT" ] && [ -f "$TYPECHECK_OUT" ]; then
        printf '\n```\n'; tail -60 "$TYPECHECK_OUT"; printf '```\n'
      else
        printf '\nSee static-failures.md for the errors.\n'
      fi
      if [ "$SUITE_SKIPPED" -eq 1 ]; then
        printf '\nTest suite not run: fix the typecheck errors first.\n'
      fi
    fi
    if [ "$LINT_EXIT" -gt 0 ]; then
      printf '\n## Lint failed (`%s`)\n' "$LINT_CMD"
      if [ -n "$LINT_OUT" ] && [ -f "$LINT_OUT" ]; then
        printf '\n```\n'; tail -60 "$LINT_OUT"; printf '```\n'
      else
        printf '\nSee static-failures.md for the errors.\n'
      fi
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

# Runs typecheck + lint concurrently, collecting real exit codes into
# TYPECHECK_EXIT / LINT_EXIT and their output into TYPECHECK_OUT / LINT_OUT.
run_static_checks() {
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
}

# Static-gate report: typecheck/lint output + a `static` phase row. Mirrors the
# typecheck/lint half of write_reports so the fix agent gets the real errors.
write_static_report() {
  local scratch="$1" exit_code="$2"
  {
    printf '# Static Failures\n'
    if [ "$TYPECHECK_EXIT" -gt 0 ]; then
      printf '\n## Typecheck failed (`%s`)\n\n```\n' "$TYPECHECK_CMD"
      tail -60 "$TYPECHECK_OUT"
      printf '```\n'
    fi
    if [ "$LINT_EXIT" -gt 0 ]; then
      printf '\n## Lint failed (`%s`)\n\n```\n' "$LINT_CMD"
      tail -60 "$LINT_OUT"
      printf '```\n'
    fi
  } > "$scratch/static-failures.md"

  local gate="pass"
  [ "$exit_code" -ne 0 ] && gate="fail"
  local ts run_placeholder
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_placeholder='#<RUN>'
  printf '| static | %s | %s | - | %s | 0 | 0 | 0 | 0 | |\n' "$run_placeholder" "$ts" "$gate" > "$scratch/phase-status-static.md"
}

main() {
  local scratch="" config="ship/config.md" static_only=0 print_static=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      --static-only) static_only=1; shift ;;
      --print-static) print_static=1; shift ;;
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

  TYPECHECK_CMD=""
  LINT_CMD=""
  TYPECHECK_EXIT=0
  LINT_EXIT=0
  TYPECHECK_OUT=""
  LINT_OUT=""
  SUITE_SKIPPED=0
  RUN_OUTPUT_FILE=""
  RUN_EXIT_CODE=0
  TEST_ENTRIES=""
  LAYER_CMD_WORDS=()
  LAYER_USES_PKG_SCRIPT=0

  # --print-static: resolve the two commands and print them, running nothing. The
  # implementer is handed these in its dispatch args so it checks exactly what the
  # pipeline checks — it used to read only `ship/config.md → Typecheck` and skip
  # when that field was absent, while this resolution also probes stack.md and
  # package.json, so develop silently skipped checks the gate then failed on.
  if [ "$print_static" -eq 1 ]; then
    PKG="$(field_from "$scratch/stack.md" 'Package Manager')"
    is_resolved "$PKG" || PKG="$(field_from "$config" 'Package Manager')"
    resolve_static_checks "$scratch" "$config"
    is_resolved "$TYPECHECK_CMD" && printf 'typecheck=%s\n' "$TYPECHECK_CMD"
    is_resolved "$LINT_CMD" && printf 'lint=%s\n' "$LINT_CMD"
    if ! is_resolved "$TYPECHECK_CMD" && ! is_resolved "$LINT_CMD"; then
      exit 2
    fi
    exit 0
  fi

  # --static-only: the pre-verify static gate. Runs typecheck+lint only, needs no
  # test runner. Exit 2 when neither check resolves (repos without them).
  if [ "$static_only" -eq 1 ]; then
    PKG="$(field_from "$scratch/stack.md" 'Package Manager')"
    is_resolved "$PKG" || PKG="$(field_from "$config" 'Package Manager')"
    resolve_static_checks "$scratch" "$config"
    if ! is_resolved "$TYPECHECK_CMD" && ! is_resolved "$LINT_CMD"; then
      exit 2
    fi
    run_static_checks
    local st_overall=0
    { [ "$TYPECHECK_EXIT" -gt 0 ] || [ "$LINT_EXIT" -gt 0 ]; } && st_overall=1
    printf 'typecheck=%s\nlint=%s\n' "$TYPECHECK_EXIT" "$LINT_EXIT" > "$scratch/static-exits.txt"
    write_static_report "$scratch" "$st_overall"
    [ -n "$TYPECHECK_OUT" ] && rm -f "$TYPECHECK_OUT"
    [ -n "$LINT_OUT" ] && rm -f "$LINT_OUT"
    exit "$st_overall"
  fi

  resolve_runner "$scratch" "$config"
  if ! is_resolved "$RUNNER"; then
    echo "test command not found: $config" >&2
    exit 2
  fi

  build_test_command "$RUNNER" "$PKG"

  resolve_static_checks "$scratch" "$config"

  # The static checks already ran before the fan-out — don't repeat them, but do
  # carry their real result forward. They no longer block the pipeline, so their
  # having run says nothing about whether they passed; assuming green here would
  # run the suite against code that does not compile and bury the real cause
  # under a cascade of unrelated test errors.
  if [ -f "$scratch/static-exits.txt" ]; then
    TYPECHECK_EXIT="$(grep -m1 '^typecheck=' "$scratch/static-exits.txt" | cut -d= -f2)"
    LINT_EXIT="$(grep -m1 '^lint=' "$scratch/static-exits.txt" | cut -d= -f2)"
    TYPECHECK_EXIT="${TYPECHECK_EXIT:-0}"
    LINT_EXIT="${LINT_EXIT:-0}"
  elif [ -f "$scratch/static-exec-done.txt" ]; then
    TYPECHECK_EXIT=0
    LINT_EXIT=0
  else
    run_static_checks
  fi

  collect_test_entries "$scratch/generated-tests.md"

  if [ "$TYPECHECK_EXIT" -gt 0 ]; then
    SUITE_SKIPPED=1
    RUN_EXIT_CODE=1
    FAILED_FILES=""
  else
    run_suites_by_layer
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
