#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pipeline.sh <subcommand> [args...]" >&2
  echo "  next            <task-id> [--mode check|fresh|resume] [--answer <token>] [--config <path>]" >&2
  echo "  init            <task-id> [--mode check|fresh|resume] [--config <path>]" >&2
  echo "  dispatch        <scratch-dir> <phase> <tool> <name> <model>" >&2
  echo "  complete        <scratch-dir> <run-number> <phase>..." >&2
  echo "  gate            <scratch-dir> [--config <path>]" >&2
  echo "  rows            <scratch-dir>" >&2
  echo "  iter            <scratch-dir> <counter-name> [--max N]" >&2
  echo "  report-timings  <scratch-dir>" >&2
  echo "  post-develop    <scratch-dir>" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# Sibling hooks pipeline.sh shells out to. Verified once at init so a broken
# install fails with the resolved path instead of a raw "No such file" mid-run
# (or an agent guessing "missing" from reading a call site it never confirmed).
REQUIRED_HOOKS="capture-diff.sh diff-classify.sh snapshot-files.sh status-consolidate.sh evidence-gate.sh quality-scope.sh test-scope.sh test-exec.sh plan-scope.sh plan-validate.sh analyze-precheck.sh analyze-correlate.sh diff-slice.sh rerun-scope.sh findings-gate.sh pipeline.sh"

require_hooks() {
  local missing="" h
  for h in $REQUIRED_HOOKS; do
    [ -f "$HOOK_DIR/$h" ] || missing="$missing $h"
  done
  if [ -n "$missing" ]; then
    echo "pipeline.sh: MISSING HOOK(S)$missing at HOOK_DIR=$HOOK_DIR (resolved from \$0=$0)" >&2
    exit 1
  fi
}

KNOWN_PHASES="plan dev test perf security review analyze homolog"

is_known_phase() {
  local phase="$1"
  local candidate
  for candidate in $KNOWN_PHASES; do
    [ "$candidate" = "$phase" ] && return 0
  done
  return 1
}

init_usage() {
  echo "usage: pipeline.sh init <task-id> [--mode check|fresh|resume] [--config <path>]" >&2
  echo "  check  (default): detect an interrupted prior run; exit 3 with a RESUME report" >&2
  echo "                    when dispatch rows exist, otherwise perform a fresh init" >&2
  echo "  fresh:  initialize the scratch dir from scratch (overwrites canonical files)" >&2
  echo "  resume: preserve existing state; only re-capture diff.md and re-classify" >&2
}

cmd_init() {
  local TASK_ID=""
  local MODE="check"
  local CONFIG="ship/config.md"

  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --config) CONFIG="$2"; shift 2 ;;
      -h|--help) init_usage; exit 0 ;;
      -*) init_usage; exit 1 ;;
      *)
        if [ -z "$TASK_ID" ]; then TASK_ID="$1"; else init_usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$TASK_ID" ]; then
    init_usage
    exit 1
  fi
  case "$TASK_ID" in
    *[!a-zA-Z0-9_-]*)
      echo "pipeline.sh init: invalid task id (allowed: [a-zA-Z0-9_-]): $TASK_ID" >&2
      exit 1 ;;
  esac
  case "$MODE" in
    check|fresh|resume) ;;
    *) init_usage; exit 1 ;;
  esac

  require_hooks

  local SCRATCH=".context/ship-run/$TASK_ID"
  local DISPATCH_LOG="$SCRATCH/dispatch-log.md"
  local PHASE_STATUS="$SCRATCH/phase-status.md"

  init_phases_in() {
    local f="$1"
    [ -f "$f" ] || return 0
    awk -F'|' 'NR > 2 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 != "" && $2 != "Phase" && $2 !~ /^-+$/) print $2 }' "$f" | sort -u
  }

  if [ "$MODE" = "check" ]; then
    local rows=0
    if [ -f "$DISPATCH_LOG" ]; then
      rows="$(awk -F'|' 'NR > 2 && NF > 2 { p = $2; gsub(/[[:space:]]/, "", p); if (p != "" && p !~ /^-+$/) n++ } END { print n + 0 }' "$DISPATCH_LOG")"
    fi
    if [ "$rows" -gt 0 ]; then
      local dispatched completed unfinished last
      dispatched="$(init_phases_in "$DISPATCH_LOG" | tr '\n' ',' | sed 's/,$//')"
      completed="$(init_phases_in "$PHASE_STATUS" | tr '\n' ',' | sed 's/,$//')"
      unfinished="$(comm -23 <(init_phases_in "$DISPATCH_LOG") <(init_phases_in "$PHASE_STATUS") | tr '\n' ',' | sed 's/,$//')"
      last="$(tail -1 "$DISPATCH_LOG" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $2 " " $6 }')"
      printf 'RESUME\n'
      printf 'last_dispatch=%s\n' "$last"
      printf 'dispatched=%s\n' "${dispatched:-none}"
      printf 'completed=%s\n' "${completed:-none}"
      printf 'unfinished=%s\n' "${unfinished:-none}"
      exit 3
    fi
    MODE="fresh"
  fi

  mkdir -p "$SCRATCH"

  # Reset fix-loop counters on every re-invocation (fresh or resume): init never
  # runs on a mid-run context compaction (across which the on-disk counter must
  # survive), so clearing here can't truncate a live loop, but it does stop a
  # stale count from a prior completed cycle aborting a new loop prematurely.
  rm -f "$SCRATCH"/iteration-*.txt

  if [ "$MODE" = "fresh" ]; then
    if [ ! -f "$CONFIG" ]; then
      echo "pipeline.sh init: config not found: $CONFIG (run /ship:init first)" >&2
      exit 1
    fi

    init_field() {
      grep -m1 -E "^- $1:" "$CONFIG" 2>/dev/null | sed -E "s/^- $1:[[:space:]]*//" || true
    }
    {
      printf '# Stack\n\n'
      local f v
      for f in Runtime Framework 'Package Manager' 'Test Framework' Typecheck Lint; do
        v="$(init_field "$f")"
        printf -- '- %s: %s\n' "$f" "${v:-unknown}"
      done
    } > "$SCRATCH/stack.md"

    printf '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n' > "$PHASE_STATUS"
    printf '# Dispatch Log\n\n| Phase | Tool | Name | Model | Timestamp |\n|-------|------|------|-------|-----------|\n' > "$DISPATCH_LOG"

    git rev-parse HEAD > "$SCRATCH/pre-quality-snapshot.sha"
    bash "$HOOK_DIR/snapshot-files.sh" snapshot "$SCRATCH/pre-develop-files.txt"
  fi

  bash "$HOOK_DIR/capture-diff.sh" "$SCRATCH/diff.md"
  local CLASS_OUT
  CLASS_OUT="$(bash "$HOOK_DIR/diff-classify.sh" "$SCRATCH/diff.md" "$SCRATCH/diff-class.txt")"

  printf 'INIT %s\n' "$MODE"
  printf 'scratch=%s\n' "$SCRATCH"
  printf 'diff_class=%s\n' "$CLASS_OUT"
}

cmd_dispatch() {
  if [ $# -ne 5 ]; then
    usage
    exit 1
  fi
  local scratch_dir="$1"
  local phase="$2"
  local tool="$3"
  local name="$4"
  local model="$5"

  if ! is_known_phase "$phase"; then
    echo "pipeline.sh dispatch: unknown phase: $phase" >&2
    exit 1
  fi

  local ts epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date -u +%s)"

  printf '| %s | %s | %s | %s | %s |\n' "$phase" "$tool" "$name" "$model" "$ts" >> "$scratch_dir/dispatch-log.md"
  # Wall-clock instrumentation: one row per dispatch. report-timings pairs
  # consecutive rows into per-phase durations — the breakdown that turns "the
  # pipeline felt slow" into "phase X took N seconds". Skipped dispatches
  # (tool=skipped) are recorded too so a zero-duration skip is visible.
  printf '%s\t%s\t%s\t%s\n' "$epoch" "$phase" "$tool" "$name" >> "$scratch_dir/timings.tsv"
  echo "▶ Fase: $phase | tool=$tool | name=$name | model=$model"
}

cmd_complete() {
  if [ $# -lt 3 ]; then
    usage
    exit 1
  fi
  local scratch_dir="$1"
  local run_number="$2"
  shift 2

  local files=()
  local phase
  for phase in "$@"; do
    files+=("$scratch_dir/phase-status-$phase.md")
  done

  local output
  if ! output="$(bash "$HOOK_DIR/status-consolidate.sh" "$run_number" "${files[@]}")"; then
    exit 1
  fi

  printf '%s\n' "$output" >> "$scratch_dir/phase-status.md"
}

iter_usage() {
  echo "usage: pipeline.sh iter <scratch-dir> <counter-name> [--max N]" >&2
  echo "  increments a persisted counter (survives context resets); exits 2 once it exceeds --max" >&2
}

cmd_iter() {
  local scratch="" name="" max=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --max) max="$2"; shift 2 ;;
      -h|--help) iter_usage; exit 0 ;;
      -*) iter_usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1";
        elif [ -z "$name" ]; then name="$1";
        else iter_usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$scratch" ] || [ -z "$name" ]; then
    iter_usage
    exit 1
  fi
  case "$name" in
    *[!a-zA-Z0-9_-]*)
      echo "pipeline.sh iter: invalid counter name (allowed: [a-zA-Z0-9_-]): $name" >&2
      exit 1 ;;
  esac
  if [ -n "$max" ]; then
    case "$max" in
      *[!0-9]*|'')
        echo "pipeline.sh iter: --max must be a positive integer: $max" >&2
        exit 1 ;;
    esac
  fi

  mkdir -p "$scratch"
  local counter_file="$scratch/iteration-$name.txt"
  local current=0
  if [ -f "$counter_file" ]; then
    current="$(cat "$counter_file")"
  fi
  local next=$((current + 1))
  printf '%s\n' "$next" > "$counter_file"

  printf 'count=%s\n' "$next"
  if [ -n "$max" ] && [ "$next" -gt "$max" ]; then
    exit 2
  fi
}

post_develop_usage() {
  echo "usage: pipeline.sh post-develop <scratch-dir>" >&2
  echo "  Runs the full post-develop sequence in one call: refresh diff.md, re-classify," >&2
  echo "  snapshot the tree, diff it against the pre-develop snapshot for mutation evidence," >&2
  echo "  and check untested touched files. Replaces five separate orchestrator invocations." >&2
  echo "  Prints: diff_class=<class>  evidence=ok|warn|fail  untested=<n>" >&2
}

cmd_post_develop() {
  local scratch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) post_develop_usage; exit 0 ;;
      -*) post_develop_usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else post_develop_usage; exit 1; fi
        shift ;;
    esac
  done
  if [ -z "$scratch" ]; then post_develop_usage; exit 1; fi

  local pre="$scratch/pre-develop-files.txt"
  if [ ! -f "$pre" ]; then
    echo "pipeline.sh post-develop: pre-develop snapshot not found: $pre (run 'init' first)" >&2
    exit 1
  fi

  # 1. develop writes to the tree without committing, so refresh the diff + class.
  bash "$HOOK_DIR/capture-diff.sh" "$scratch/diff.md"
  local class
  class="$(bash "$HOOK_DIR/diff-classify.sh" "$scratch/diff.md" "$scratch/diff-class.txt")"

  # 2. Mutation evidence: snapshot the tree, diff against the pre-develop snapshot.
  #    A non-empty set is develop's verified footprint — trusted over its self-report.
  bash "$HOOK_DIR/snapshot-files.sh" snapshot "$scratch/post-develop-files.txt"
  bash "$HOOK_DIR/snapshot-files.sh" diff "$pre" "$scratch/post-develop-files.txt" \
    > "$scratch/develop-touched-files.txt"

  local evidence
  if [ -s "$scratch/develop-touched-files.txt" ]; then
    evidence="ok"
  elif [ -s "$scratch/diff.md" ] && grep -q '^diff --git ' "$scratch/diff.md"; then
    # No new mutation this turn but the tree already carries work → re-run, not a no-op.
    evidence="warn"
  else
    # No mutation and an empty diff → develop never ran. Caller must STOP.
    evidence="fail"
  fi

  # 3. Untested touched files (non-blocking): count source files with no sibling test.
  local untested=0
  if [ -s "$scratch/develop-touched-files.txt" ]; then
    untested="$(bash "$HOOK_DIR/evidence-gate.sh" "$scratch/develop-touched-files.txt" \
      | grep -oE '"untested":\[[^]]*\]' | sed 's/"untested"://' \
      | grep -oE '"[^"]*"' | grep -c '"' || true)"
    untested="${untested:-0}"
  fi

  printf 'diff_class=%s\n' "$class"
  printf 'evidence=%s\n' "$evidence"
  printf 'untested=%s\n' "$untested"
}

report_timings_usage() {
  echo "usage: pipeline.sh report-timings <scratch-dir>" >&2
  echo "  prints per-phase wall-clock durations from timings.tsv (consecutive-dispatch deltas) + total" >&2
}

cmd_report_timings() {
  local scratch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) report_timings_usage; exit 0 ;;
      -*) report_timings_usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else report_timings_usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$scratch" ]; then report_timings_usage; exit 1; fi
  local timings="$scratch/timings.tsv"
  if [ ! -f "$timings" ]; then
    echo "pipeline.sh report-timings: timings.tsv not found: $timings" >&2
    exit 1
  fi

  local now
  now="$(date -u +%s)"

  # Each row's duration = next row's epoch − this row's epoch; the final row runs
  # until now (the phase is still in flight, or just handed control back). Total =
  # last dispatch's start-to-now span, i.e. the whole pipeline's wall-clock.
  awk -F'\t' -v now="$now" '
    { epoch[NR] = $1; phase[NR] = $2; tool[NR] = $3; n = NR }
    END {
      if (n == 0) { print "no dispatches recorded"; exit }
      printf "%-10s %-8s %8s\n", "phase", "tool", "seconds"
      for (i = 1; i <= n; i++) {
        end = (i < n) ? epoch[i + 1] : now
        dur = end - epoch[i]
        if (dur < 0) dur = 0
        printf "%-10s %-8s %8d\n", phase[i], tool[i], dur
      }
      total = now - epoch[1]
      if (total < 0) total = 0
      printf "%-10s %-8s %8d\n", "TOTAL", "", total
    }
  ' "$timings"
}

gate_usage() {
  echo "usage: pipeline.sh gate <scratch-dir> [--config <path>]" >&2
}

rows_usage() {
  echo "usage: pipeline.sh rows <scratch-dir>" >&2
  echo "  prints the most recent full phase-status.md row for each phase, in first-seen order" >&2
}

cmd_rows() {
  local scratch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) rows_usage; exit 0 ;;
      -*) rows_usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else rows_usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$scratch" ]; then rows_usage; exit 1; fi
  local phase_status="$scratch/phase-status.md"
  if [ ! -f "$phase_status" ]; then
    echo "pipeline.sh rows: phase-status.md not found: $phase_status" >&2
    exit 1
  fi

  awk -F'|' '
    $0 ~ /^\|/ {
      phase = $2
      gsub(/^[ \t]+|[ \t]+$/, "", phase)
      if (phase == "" || phase == "Phase" || phase ~ /^-+$/) next
      if (!(phase in seen)) order[++n] = phase
      seen[phase] = 1
      line[phase] = $0
    }
    END { for (i = 1; i <= n; i++) print line[order[i]] }
  ' "$phase_status"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

config_field() {
  local config="$1" key="$2"
  grep -m1 -E "^- $key:" "$config" 2>/dev/null | sed -E "s/^- $key:[[:space:]]*//" || true
}

dispatched_phases_in_log() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -F'|' '
    NR > 2 {
      phase = $2; tool = $3; name = $4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", phase)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", tool)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (phase != "" && phase != "Phase" && phase !~ /^-+$/ && tool != "skipped" && name != "skipped") print phase
    }
  ' "$f" | sort -u
}

last_rows_by_phase() {
  local phase_status="$1"
  awk -F'|' '
    $0 ~ /^\|/ {
      phase = $2
      gsub(/^[ \t]+|[ \t]+$/, "", phase)
      if (phase == "" || phase == "Phase" || phase ~ /^-+$/) next
      crit = $7; high = $8; med = $9; low = $10
      gsub(/^[ \t]+|[ \t]+$/, "", crit)
      gsub(/^[ \t]+|[ \t]+$/, "", high)
      gsub(/^[ \t]+|[ \t]+$/, "", med)
      gsub(/^[ \t]+|[ \t]+$/, "", low)
      if (!(phase in seen)) order[++n] = phase
      seen[phase] = 1
      critv[phase] = crit
      highv[phase] = high
      medv[phase] = med
      lowv[phase] = low
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        printf "%s\t%s\t%s\t%s\t%s\n", p, critv[p] + 0, highv[p] + 0, medv[p] + 0, lowv[p] + 0
      }
    }
  ' "$phase_status"
}

normalize_severity() {
  local s="$1"
  case "$s" in
    critical|high|medium|low) printf '%s' "$s"; return 0 ;;
    warn) printf '%s' "medium"; return 0 ;;
    *) return 1 ;;
  esac
}

get_eff() {
  case "$1" in
    critical) printf '%s' "$eff_crit" ;;
    high) printf '%s' "$eff_high" ;;
    medium) printf '%s' "$eff_med" ;;
    low) printf '%s' "$eff_low" ;;
  esac
}

set_eff() {
  case "$1" in
    critical) eff_crit="$2" ;;
    high) eff_high="$2" ;;
    medium) eff_med="$2" ;;
    low) eff_low="$2" ;;
  esac
}

severity_override_lines() {
  local config="$1"
  [ -f "$config" ] || return 0
  awk '
    /^## Severity Overrides/ { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^-[[:space:]]*[A-Za-z0-9_-]+:/ { print }
  ' "$config"
}

run_gate() {
  local scratch=""
  local config="ship/config.md"

  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      -h|--help) gate_usage; exit 0 ;;
      -*) gate_usage; exit 1 ;;
      *)
        if [ -z "$scratch" ]; then scratch="$1"; else gate_usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$scratch" ]; then
    gate_usage
    exit 1
  fi

  local phase_status="$scratch/phase-status.md"

  if [ ! -f "$phase_status" ]; then
    echo "pipeline.sh gate: phase-status.md not found: $phase_status" >&2
    exit 1
  fi

  local rows
  rows="$(last_rows_by_phase "$phase_status")"
  if [ -z "$rows" ]; then
    echo "pipeline.sh gate: phase-status.md has no phase rows: $phase_status" >&2
    exit 1
  fi

  local valid_phases="dev test analyze perf security review frontend-perf database backend"

  local dispatched completed_phases scored_dispatched unfinished
  dispatched="$(dispatched_phases_in_log "$scratch/dispatch-log.md")"
  completed_phases="$(printf '%s\n' "$rows" | awk -F'\t' '{print $1}' | sort -u)"
  scored_dispatched="$(comm -12 <(printf '%s\n' "$dispatched") <(printf '%s\n' "$valid_phases" | tr ' ' '\n' | sort -u))"
  unfinished="$(comm -23 <(printf '%s\n' "$scored_dispatched") <(printf '%s\n' "$completed_phases") | sed '/^$/d')"
  if [ -n "$unfinished" ]; then
    echo "pipeline.sh gate: phase(s) dispatched but not completed — missing phase-status.md row(s): $(printf '%s' "$unfinished" | tr '\n' ',' | sed 's/,$//')" >&2
    echo "pipeline.sh gate: wait for the dispatched phase to finish (or re-dispatch it) before evaluating the gate" >&2
    exit 1
  fi

  local -a override_phase=() override_from=() override_to=()
  local line phase from to rest is_valid_phase p norm_from norm_to

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    phase="$(printf '%s\n' "$line" | sed -E 's/^-[[:space:]]*([A-Za-z0-9_-]+):.*/\1/')"
    rest="$(printf '%s\n' "$line" | sed -E 's/^-[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*//')"
    IFS=$'\t' read -r from to <<< "$(printf '%s' "$rest" | awk -F'→' '{ printf "%s\t%s", $1, $2 }')"
    from="$(trim "$from")"
    to="$(trim "$to")"

    is_valid_phase="false"
    for p in $valid_phases; do
      if [ "$p" = "$phase" ]; then is_valid_phase="true"; fi
    done
    if [ "$is_valid_phase" = "false" ]; then
      echo "Severity override refers to unknown phase: $phase" >&2
      exit 1
    fi

    if ! norm_from="$(normalize_severity "$from")"; then
      echo "Severity override refers to unknown severity level: $from" >&2
      exit 1
    fi
    if ! norm_to="$(normalize_severity "$to")"; then
      echo "Severity override refers to unknown severity level: $to" >&2
      exit 1
    fi

    override_phase+=("$phase")
    override_from+=("$norm_from")
    override_to+=("$norm_to")
  done < <(severity_override_lines "$config")

  local i j
  for ((i = 0; i < ${#override_phase[@]}; i++)); do
    for ((j = i + 1; j < ${#override_phase[@]}; j++)); do
      if [ "${override_phase[$i]}" = "${override_phase[$j]}" ]; then
        echo "Severity override refers to phase already overridden: ${override_phase[$i]}" >&2
        exit 1
      fi
    done
  done

  local total_crit=0 total_high=0 total_med=0
  local crit high med low eff_crit eff_high eff_med eff_low i n_over from_val to_val

  n_over="${#override_phase[@]}"

  while IFS=$'\t' read -r p crit high med low; do
    eff_crit="$crit"
    eff_high="$high"
    eff_med="$med"
    eff_low="$low"

    for ((i = 0; i < n_over; i++)); do
      if [ "${override_phase[$i]}" != "$p" ]; then continue; fi
      from="${override_from[$i]}"
      to="${override_to[$i]}"
      from_val="$(get_eff "$from")"
      set_eff "$from" 0
      to_val="$(get_eff "$to")"
      set_eff "$to" $((to_val + from_val))
    done

    total_crit=$((total_crit + eff_crit))
    total_high=$((total_high + eff_high))
    total_med=$((total_med + eff_med))
  done <<< "$rows"

  local decision exit_code
  if [ "$total_crit" -gt 0 ] || [ "$total_high" -gt 0 ]; then
    decision="FAIL"
    exit_code=2
  elif [ "$total_med" -gt 0 ]; then
    decision="WARN"
    exit_code=1
  else
    decision="PASS"
    exit_code=0
  fi

  local on_fail on_warn action
  on_fail="$(config_field "$config" "on_fail")"
  on_warn="$(config_field "$config" "on_warn")"
  on_fail="${on_fail:-ask}"
  on_warn="${on_warn:-ask}"

  case "$decision" in
    FAIL) action="$on_fail" ;;
    WARN) action="$on_warn" ;;
    PASS) action="continue" ;;
  esac

  printf 'decision=%s\n' "$decision"
  printf 'action=%s\n' "$action"
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# next — the pipeline state machine. Each call derives the current state from
# the scratch dir's on-disk artifacts, performs every deterministic step it
# can (init, scoping, validation, consolidation, test execution, gating), and
# stops at the first point that needs an LLM or the user — emitting exactly
# one instruction block for the orchestrator to execute before calling next
# again. The orchestrator never sequences phases itself; it is a loop around
# this subcommand.
#
# Output protocol (stdout):
#   state=<name>      current state machine node
#   action=work|dispatch|ask|stop|done
#   run=<N>           current run number (increments per surgical re-run round)
#   log=<one-liner>
#   instruction:      free-text block with the exact tool calls / question
# ---------------------------------------------------------------------------

next_usage() {
  echo "usage: pipeline.sh next <task-id> [--mode check|fresh|resume] [--answer <token>] [--config <path>]" >&2
  echo "  Derives the pipeline state from .context/ship-run/<task-id> and prints the" >&2
  echo "  next instruction. --answer resolves a pending action=ask (token depends on" >&2
  echo "  the asking state). --mode fresh discards prior state." >&2
}

config_section_field() {
  local config="$1" section="$2" key="$3" v
  [ -f "$config" ] || return 0
  v="$(awk -v h="$section" '
    $0 ~ "^## " h "$" { insection = 1; next }
    /^## / { insection = 0 }
    insection { print }
  ' "$config" | grep -m1 -E "^-[[:space:]]*$key:" | sed -E "s/^-[[:space:]]*$key:[[:space:]]*//" || true)"
  printf '%s' "$v"
}

# dev/test/homolog have no profile defaults — enabled unless a Pipeline Phases
# override disables them (perf/security/review enablement lives in quality-scope.sh).
phase_toggle() {
  local config="$1" phase="$2" v
  v="$(config_section_field "$config" "Pipeline Phases" "$phase" | awk '{print $1}')"
  printf '%s' "${v:-enabled}"
}

artifact_lang() {
  local config="$1" v
  v="$(config_field "$config" "Artifact language")"
  printf '%s' "${v:-English}"
}

storage_mode() {
  local config="$1" v
  v="$(config_section_field "$config" "Linear Integration" "Configured" | awk '{print $1}')"
  if [ "$v" = "yes" ]; then printf 'linear'; else printf 'local'; fi
}

next_dispatched() {
  local scratch="$1" phase="$2"
  dispatched_phases_in_log "$scratch/dispatch-log.md" | grep -qx "$phase"
}

next_run_number() {
  local scratch="$1"
  if [ -f "$scratch/run-number.txt" ]; then cat "$scratch/run-number.txt"; else printf '1'; fi
}

# Consolidate every per-phase scratch row not yet folded into phase-status.md.
# Tracked via consolidated-<phase>.txt markers so rows are appended exactly once
# per (phase, run) pair.
next_consolidate() {
  local scratch="$1" run="$2" phase f marker
  shift 2
  for phase in "$@"; do
    f="$scratch/phase-status-$phase.md"
    marker="$scratch/consolidated-$phase.txt"
    [ -f "$f" ] || continue
    # The marker holds a copy of the last consolidated scratch row — a phase is
    # re-consolidated only when its agent wrote a genuinely new row (re-runs).
    if [ -f "$marker" ] && cmp -s "$f" "$marker"; then
      continue
    fi
    bash "$HOOK_DIR/status-consolidate.sh" "$run" "$f" >> "$scratch/phase-status.md"
    cp "$f" "$marker"
  done
}

next_write_row() {
  local scratch="$1" phase="$2" gate="$3" notes="$4" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| %s | #<RUN> | %s | - | %s | 0 | 0 | 0 | 0 | %s |\n' "$phase" "$ts" "$gate" "$notes" \
    > "$scratch/phase-status-$phase.md"
}

# Predict a single-module task from the spec slice: ## Files with ≤3 code file
# bullets (plugins/** rebuild lines excluded), Dependencies: None, and at most
# one test-layer tag across its scenarios.
plan_predict_single_module() {
  local spec="$1" files layers
  [ -f "$spec" ] || return 1
  grep -qE '^## Files' "$spec" || return 1
  files="$(awk '/^## Files/{f=1;next} /^#/{f=0} f && /^- /' "$spec" | grep -cvE '(^- *`?plugins/)' || true)"
  [ "${files:-0}" -ge 1 ] && [ "${files:-0}" -le 3 ] || return 1
  grep -qiE 'Dependencies:[[:space:]]*None' "$spec" || return 1
  layers="$(grep -oE '@(unit|integration|e2e)' "$spec" | sort -u | wc -l | tr -d ' ')"
  [ "${layers:-0}" -le 1 ]
}

# Per-layer worker brief: contract slots + de-identified scenarios + denylist +
# source pointer, derived deterministically from plan.md/spec.md. Replaces the
# ship:test orchestrator's inline context slicing.
next_test_brief() {
  local scratch="$1" layer="$2"
  local plan="$scratch/plan.md" spec="$scratch/spec.md" out="$scratch/test-brief-$layer.md"
  {
    printf '# Test Brief — %s\n\n## Test Contract\n\n' "$layer"
    if [ -f "$plan" ]; then
      awk -v layer="$layer" '
        /^### / {
          if ($0 ~ /^### @?SC-[0-9]+/ && $0 ~ ("->[[:space:]]*" layer "[[:space:]]*->")) capture = 1
          else capture = 0
        }
        /^## / { capture = 0 }
        capture { print }
      ' "$plan"
    fi
    printf '\n## Scenarios\n\n'
    if [ -f "$spec" ] && grep -qE '@(unit|integration|e2e)' "$spec"; then
      awk -v layer="$layer" '
        /^[[:space:]]*@/ { tags = tags " " $0; capture = 0; next }
        /^[[:space:]]*(Scenario Outline:|Scenario:|Cenário:)/ {
          capture = (tags ~ ("@" layer)) ? 1 : 0
          tags = ""
          if (capture) { print; next } else next
        }
        /^#/ { capture = 0; tags = ""; next }
        capture { print }
      ' "$spec"
    else
      printf 'No tagged scenarios found — derive behaviors from the Acceptance Criteria in %s.\n' "$spec"
    fi
    printf '\n## Denylist\n\n'
    if [ -f "$plan" ]; then
      grep -E '^- Files:' "$plan" | sed -E 's/^- Files:[[:space:]]*//' | tr ',' '\n' \
        | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$' | sed 's/^/- /' || true
    else
      awk '/^## Files/{f=1;next} /^#/{f=0} f && /^- /' "$spec" 2>/dev/null || true
    fi
    printf '\n## Source\n\nRead the full diff from %s/diff.md; read surrounding project code as needed.\n' "$scratch"
  } > "$out"
}

NEXT_BODY=""

next_emit() {
  local state="$1" action="$2" run="$3" log="$4"
  printf 'state=%s\naction=%s\nrun=%s\nlog=%s\ninstruction:\n%s\n' "$state" "$action" "$run" "$log" "$NEXT_BODY"
  exit 0
}

next_body_add() {
  NEXT_BODY="${NEXT_BODY}$1
"
}

next_common_after() {
  next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/pipeline.sh\" next <task-id> — do not evaluate results yourself."
}

next_quality_dispatch() {
  local scratch="$1" task="$2" lang="$3" mode="$4" phase="$5" depth="$6"
  local extra=""
  case "$phase" in
    security) extra=" | Security Focus: ship/config.md → ## Security Focus | Diff slice script: $HOOK_DIR/diff-slice.sh" ;;
    review)   extra=" | Write review-findings.md to the scratch dir only (never ship/changes/ in Linear mode)" ;;
  esac
  cmd_dispatch "$scratch" "$phase" Agent "ship-$phase" sonnet >/dev/null
  next_body_add "- Agent subagent_type=ship:ship-$phase (model sonnet), prompt: \"Task: $task | Artifact language: $lang | Storage mode: $mode | Scratch dir: $scratch | Fan-out: $depth (flat = no sub-agents) | Findings gate script: $HOOK_DIR/findings-gate.sh | Severity overrides: ship/config.md → ## Severity Overrides | Stack: $scratch/stack.md | Read the diff from $scratch/diff.md — never recompute it$extra\""
}

next_test_dispatch() {
  local scratch="$1" task="$2" lang="$3" layer="$4"
  next_test_brief "$scratch" "$layer"
  cmd_dispatch "$scratch" test Agent "ship-test-$layer" sonnet >/dev/null
  next_body_add "- Agent subagent_type=ship:ship-test-$layer (model sonnet), prompt: \"Task ID: $task | Mode: generate | Artifact language: $lang | Brief: $scratch/test-brief-$layer.md — read it first; it contains this layer's Test Contract (source of truth), Scenarios, Denylist (paths you must never touch) and Source pointer; do not fall back to standalone discovery | Manifest: write one line per file you actually create, as '- <path> ($layer)', to $scratch/generated-tests-$layer.md (no header; write the file even when empty). Generate only — never run a test command.\""
}

next_fix_dispatch() {
  local scratch="$1" task="$2" lang="$3" kind="$4" source_file="$5"
  next_body_add "- Agent subagent_type=general-purpose (model sonnet), prompt: \"Task: $task | Artifact language: $lang | Read $source_file and apply the minimal source fixes for the listed $kind findings/failures — no unrelated refactors, no comments, no spec IDs in code. Report what you changed.\""
}

cmd_next() {
  local TASK_ID="" MODE="check" CONFIG="ship/config.md" ANSWER=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --answer) ANSWER="$2"; shift 2 ;;
      --config) CONFIG="$2"; shift 2 ;;
      -h|--help) next_usage; exit 0 ;;
      -*) next_usage; exit 1 ;;
      *)
        if [ -z "$TASK_ID" ]; then TASK_ID="$1"; else next_usage; exit 1; fi
        shift ;;
    esac
  done
  if [ -z "$TASK_ID" ]; then next_usage; exit 1; fi
  case "$TASK_ID" in
    *[!a-zA-Z0-9_-]*)
      echo "pipeline.sh next: invalid task id (allowed: [a-zA-Z0-9_-]): $TASK_ID" >&2
      exit 1 ;;
  esac

  local SCRATCH=".context/ship-run/$TASK_ID"
  local RUN LANG_ STORE resumed=""

  # --- init (first call, or forced fresh/resume) -------------------------------
  if [ ! -f "$SCRATCH/diff-class.txt" ] || [ "$MODE" != "check" ]; then
    local init_out init_rc=0
    set +e
    init_out="$(cmd_init "$TASK_ID" --mode "$MODE" --config "$CONFIG" 2>&1)"
    init_rc=$?
    set -e
    if [ "$init_rc" -eq 3 ]; then
      set +e
      init_out="$(cmd_init "$TASK_ID" --mode resume --config "$CONFIG" 2>&1)"
      init_rc=$?
      set -e
      resumed="resumed interrupted run — state preserved (use --mode fresh to discard); "
    fi
    if [ "$init_rc" -ne 0 ]; then
      printf '%s\n' "$init_out" >&2
      exit 1
    fi
  fi

  RUN="$(next_run_number "$SCRATCH")"
  LANG_="$(artifact_lang "$CONFIG")"
  STORE="$(storage_mode "$CONFIG")"

  # --- context staging (judgment: Linear/local artifact slicing) ---------------
  if [ ! -s "$SCRATCH/spec.md" ]; then
    next_body_add "Stage the task context yourself (no sub-agent):"
    if [ "$STORE" = "linear" ]; then
      next_body_add "- Fetch the issue and project documents via Linear MCP (get_issue/get_project/list_documents+get_document) and move the issue to its started state per $HOOK_DIR/../patterns/linear-status.md."
    else
      next_body_add "- Read ship/changes/<feature>/proposal.md and design.md per $HOOK_DIR/../patterns/load-artifacts.md."
    fi
    next_body_add "- Write $SCRATCH/spec.md (per-task slice) and $SCRATCH/design.md per $HOOK_DIR/../patterns/run-context.md (spec slice + scope-index format)."
    next_common_after
    next_emit "context" "work" "$RUN" "${resumed}task context not yet staged"
  fi

  # --- plan decision + dispatch + validation -----------------------------------
  local class
  class="$(head -1 "$SCRATCH/diff-class.txt" 2>/dev/null | awk '{print $1}')"
  class="${class:-normal}"

  if [ ! -f "$SCRATCH/plan-decision.txt" ]; then
    local decision="run" baseline="$class"
    # An empty baseline diff means no work exists yet — greenfield always plans
    # (unless the issue itself predicts a single module). trivial/minor only
    # skip the planner on top of pre-existing work.
    if ! grep -q '^diff --git ' "$SCRATCH/diff.md" 2>/dev/null; then
      baseline="greenfield"
    fi
    if [ "$(phase_toggle "$CONFIG" dev)" = "disabled" ]; then
      decision="skip:dev-disabled"
    elif plan_predict_single_module "$SCRATCH/spec.md"; then
      decision="skip:single-module"
    elif [ "$baseline" = "trivial" ] || [ "$baseline" = "minor" ]; then
      decision="skip:baseline-$baseline"
    fi
    printf '%s\n' "$decision" > "$SCRATCH/plan-decision.txt"
    if [ "$decision" != "run" ]; then
      bash "$HOOK_DIR/plan-scope.sh" "$SCRATCH" >/dev/null
    fi
  fi

  if [ "$(head -1 "$SCRATCH/plan-decision.txt")" = "run" ] && [ "$(phase_toggle "$CONFIG" dev)" != "disabled" ]; then
    if [ ! -f "$SCRATCH/plan.md" ]; then
      if next_dispatched "$SCRATCH" plan; then
        local iter_out iter_rc=0
        set +e
        iter_out="$(cmd_iter "$SCRATCH" plan-redispatch --max 2)"
        iter_rc=$?
        set -e
        if [ "$iter_rc" -eq 2 ]; then
          next_body_add "The planner returned twice without writing $SCRATCH/plan.md. Report the failure to the user and stop."
          next_emit "plan" "stop" "$RUN" "planner wrote no plan.md after retries"
        fi
        next_body_add "The planner returned without writing $SCRATCH/plan.md (silent write failure). Re-dispatch it:"
      fi
      cmd_dispatch "$SCRATCH" plan Skill ship:plan sonnet >/dev/null
      next_body_add "- Skill ship:plan (forked), args: \"Task: $TASK_ID | Artifact language: $LANG_ | Scratch dir: $SCRATCH | Storage mode: $STORE | Spec/design: read from the scratch dir\""
      next_common_after
      next_emit "plan" "dispatch" "$RUN" "${resumed}planner required for this task"
    fi
    if [ ! -f "$SCRATCH/plan-validated.txt" ]; then
      local pv_rc=0
      set +e
      bash "$HOOK_DIR/plan-validate.sh" "$SCRATCH/plan.md" >/dev/null 2>&1
      pv_rc=$?
      set -e
      if [ "$pv_rc" -eq 0 ]; then
        printf 'ok\n' > "$SCRATCH/plan-validated.txt"
      else
        case "$ANSWER" in
          replan)
            rm -f "$SCRATCH/plan.md"
            cmd_dispatch "$SCRATCH" plan Skill ship:plan sonnet >/dev/null
            next_body_add "- Skill ship:plan (forked), args: \"Task: $TASK_ID | Artifact language: $LANG_ | Scratch dir: $SCRATCH | Storage mode: $STORE | Spec/design: read from the scratch dir | Previous plan failed schema validation — fix module map/test contract per plan-validate.sh\""
            next_common_after
            next_emit "plan" "dispatch" "$RUN" "re-planning after failed validation"
            ;;
          abort)
            next_body_add "Plan validation failed and the user chose to abort. Report and stop."
            next_emit "plan" "stop" "$RUN" "aborted on invalid plan"
            ;;
          *)
            next_body_add "plan.md failed schema validation (run: bash $HOOK_DIR/plan-validate.sh $SCRATCH/plan.md — surface its stderr to the user, in the artifact language)."
            next_body_add "Ask the user: re-plan or abort? Then re-run next with --answer replan | --answer abort."
            next_emit "plan" "ask" "$RUN" "plan failed validation"
            ;;
        esac
      fi
    fi
  fi

  # --- develop ------------------------------------------------------------------
  if [ "$(phase_toggle "$CONFIG" dev)" = "disabled" ]; then
    if [ ! -f "$SCRATCH/dev-skipped.txt" ]; then
      cmd_dispatch "$SCRATCH" dev - skipped - >/dev/null
      touch "$SCRATCH/dev-skipped.txt" "$SCRATCH/post-develop-done.txt"
    fi
  else
    if ! next_dispatched "$SCRATCH" dev; then
      cmd_dispatch "$SCRATCH" dev Skill ship:develop sonnet >/dev/null
      next_body_add "- Skill ship:develop (forked), args: \"Task: $TASK_ID | Artifact language: $LANG_ | Scratch dir: $SCRATCH | Storage mode: $STORE | Spec/design: read from the scratch dir\""
      next_body_add "Dispatch develop ALONE — no other tool call this turn."
      next_common_after
      next_emit "develop" "dispatch" "$RUN" "${resumed}dispatching the implementer"
    fi
    if [ ! -f "$SCRATCH/post-develop-done.txt" ]; then
      local pd_out evidence untested
      pd_out="$(cmd_post_develop "$SCRATCH")"
      evidence="$(printf '%s\n' "$pd_out" | grep '^evidence=' | cut -d= -f2)"
      untested="$(printf '%s\n' "$pd_out" | grep '^untested=' | cut -d= -f2)"
      class="$(printf '%s\n' "$pd_out" | grep '^diff_class=' | cut -d= -f2 | awk '{print $1}')"
      if [ "$evidence" = "fail" ]; then
        next_body_add "ship:develop returned but wrote nothing to the tree (no mutation vs the pre-develop snapshot, empty diff). Report the failure and stop — manual intervention required."
        next_emit "post-develop" "stop" "$RUN" "develop produced no mutation"
      fi
      local note=""
      [ "$evidence" = "warn" ] && note="re-run, no new mutation"
      next_write_row "$SCRATCH" dev pass "$note"
      next_consolidate "$SCRATCH" "$RUN" dev
      printf '%s\n' "${untested:-0}" > "$SCRATCH/untested-count.txt"
      touch "$SCRATCH/post-develop-done.txt"
    fi
  fi

  # --- verification turn A: test-layer workers ∥ quality agents ----------------
  if [ ! -f "$SCRATCH/verify-a.txt" ]; then
    local qs qrun depth layers=""
    qs="$(bash "$HOOK_DIR/quality-scope.sh" "$class" --phases "perf security review analyze" --scratch "$SCRATCH" --config "$CONFIG")"
    qrun="$(printf '%s\n' "$qs" | grep '^run=' | sed 's/^run=//')"
    depth="$(printf '%s\n' "$qs" | grep '^depth=' | sed 's/^depth=//')"
    if [ "$(phase_toggle "$CONFIG" test)" != "disabled" ] && [ ! -f "$SCRATCH/generated-tests.md" ]; then
      layers="$(bash "$HOOK_DIR/test-scope.sh" --config "$CONFIG" | grep '^run=' | sed 's/^run=//')"
    fi
    {
      printf 'quality=%s\n' "$qrun"
      printf 'depth=%s\n' "$depth"
      printf 'layers=%s\n' "$layers"
    } > "$SCRATCH/verify-a.txt"

    local pending="" l p
    for l in $layers; do
      next_test_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "$l"
      pending="$pending layer:$l"
    done
    for p in $qrun; do
      [ "$p" = "analyze" ] && continue
      next_quality_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "$STORE" "$p" "$depth"
      pending="$pending quality:$p"
    done
    printf '%s\n' "${pending# }" > "$SCRATCH/pending.txt"
    if [ -n "${pending# }" ]; then
      next_body_add "Dispatch ALL of the above concurrently in this turn (synchronous, never backgrounded)."
      next_common_after
      next_emit "verify-a" "dispatch" "$RUN" "verification fan-out: tests [${layers:-none}] + quality [$(printf '%s' "$qrun" | sed 's/ analyze//;s/analyze//')]"
    fi
  fi

  # --- resolve pending dispatches (silent-write-failure guard) -----------------
  if [ -s "$SCRATCH/pending.txt" ]; then
    local still="" missing="" entry kind name f
    for entry in $(cat "$SCRATCH/pending.txt"); do
      kind="${entry%%:*}"
      name="${entry#*:}"
      case "$kind" in
        layer)   f="$SCRATCH/generated-tests-$name.md" ;;
        quality) f="$SCRATCH/phase-status-$name.md" ;;
      esac
      if [ ! -f "$f" ]; then
        missing="$missing $entry"
        still="$still $entry"
      fi
    done
    printf '%s\n' "${still# }" > "$SCRATCH/pending.txt"
    if [ -n "${missing# }" ]; then
      local depth_v
      depth_v="$(grep '^depth=' "$SCRATCH/verify-a.txt" | sed 's/^depth=//')"
      for entry in ${missing# }; do
        kind="${entry%%:*}"
        name="${entry#*:}"
        local rd_rc=0
        set +e
        ( cmd_iter "$SCRATCH" "redispatch-$kind-$name" --max 2 ) >/dev/null
        rd_rc=$?
        set -e
        if [ "$rd_rc" -eq 2 ]; then
          next_body_add "Phase '$entry' returned twice without writing its expected file. Report the failure and stop — manual intervention required."
          next_emit "verify-pending" "stop" "$RUN" "phase $entry silently failed twice"
        fi
        case "$kind" in
          layer)   next_test_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "$name" ;;
          quality) next_quality_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "$STORE" "$name" "$depth_v" ;;
        esac
      done
      next_body_add "The above phase(s) returned without writing their expected output (silent write failure) — re-dispatch them now."
      next_common_after
      next_emit "verify-pending" "dispatch" "$RUN" "re-dispatching phases with missing outputs"
    fi
  fi

  # --- consolidate generated-test manifests ------------------------------------
  local layers_v
  layers_v="$(grep '^layers=' "$SCRATCH/verify-a.txt" 2>/dev/null | sed 's/^layers=//')"
  if [ -n "$layers_v" ] && [ ! -f "$SCRATCH/generated-tests.md" ]; then
    {
      printf '# Generated Tests\n\n'
      local l
      for l in $layers_v; do
        [ -f "$SCRATCH/generated-tests-$l.md" ] && grep '^- ' "$SCRATCH/generated-tests-$l.md" || true
      done
    } > "$SCRATCH/generated-tests.md"
    next_write_row "$SCRATCH" test-generate pass ""
    next_consolidate "$SCRATCH" "$RUN" test-generate
  fi

  # --- test execution (deterministic; fix loop on red) -------------------------
  if [ ! -f "$SCRATCH/test-exec-done.txt" ]; then
    local te_rc=0
    set +e
    if command -v timeout >/dev/null 2>&1; then
      timeout 300 bash "$HOOK_DIR/test-exec.sh" "$SCRATCH" --config "$CONFIG" >/dev/null 2>&1
    else
      bash "$HOOK_DIR/test-exec.sh" "$SCRATCH" --config "$CONFIG" >/dev/null 2>&1
    fi
    te_rc=$?
    set -e
    case "$te_rc" in
      0)
        next_consolidate "$SCRATCH" "$RUN" test
        touch "$SCRATCH/test-exec-done.txt"
        if [ -f "$SCRATCH/test-fix-inflight.txt" ]; then
          rm -f "$SCRATCH/test-fix-inflight.txt"
          bash "$HOOK_DIR/snapshot-files.sh" snapshot "$SCRATCH/post-test-fix-files.txt"
          bash "$HOOK_DIR/snapshot-files.sh" diff "$SCRATCH/pre-test-fix-files.txt" "$SCRATCH/post-test-fix-files.txt" \
            > "$SCRATCH/test-fix-changed-files.txt" || true
          if [ -s "$SCRATCH/test-fix-changed-files.txt" ]; then
            printf 'test-fix\n' > "$SCRATCH/reconcile-source.txt"
          fi
        fi
        ;;
      124)
        next_body_add "Test suite timed out after 300s. Report and stop — manual intervention required."
        next_emit "test-exec" "stop" "$RUN" "suite timeout"
        ;;
      2)
        next_write_row "$SCRATCH" test skip "runner unresolved"
        next_consolidate "$SCRATCH" "$RUN" test
        touch "$SCRATCH/test-exec-done.txt"
        ;;
      *)
        local tf_rc=0
        set +e
        ( cmd_iter "$SCRATCH" test-fix --max 2 ) >/dev/null
        tf_rc=$?
        set -e
        if [ "$tf_rc" -eq 2 ]; then
          next_body_add "Suíte vermelha. Intervenção manual necessária. Present $SCRATCH/test-failures.md to the user and stop."
          next_emit "test-exec" "stop" "$RUN" "red suite after fix attempts"
        fi
        [ -f "$SCRATCH/pre-test-fix-files.txt" ] || bash "$HOOK_DIR/snapshot-files.sh" snapshot "$SCRATCH/pre-test-fix-files.txt"
        touch "$SCRATCH/test-fix-inflight.txt"
        next_fix_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "test failure" "$SCRATCH/test-failures.md"
        next_common_after
        next_emit "test-fix" "dispatch" "$RUN" "red suite — dispatching fix agent"
        ;;
    esac
  fi

  # --- analyze (agent only on gray-zone) ---------------------------------------
  local qrun_v
  qrun_v="$(grep '^quality=' "$SCRATCH/verify-a.txt" 2>/dev/null | sed 's/^quality=//')"
  if printf '%s' "$qrun_v" | grep -qw analyze && [ ! -f "$SCRATCH/analyze-decided.txt" ]; then
    local scope_spec pre
    scope_spec="$(bash "$HOOK_DIR/test-scope.sh" --config "$CONFIG" | awk -F= '
      $1 == "run"  { n = split($2, a, " "); for (i = 1; i <= n; i++) state[a[i]] = "enabled" }
      $1 == "skip" { n = split($2, a, " "); for (i = 1; i <= n; i++) state[a[i]] = "disabled" }
      END { printf "unit=%s,integration=%s,e2e=%s", state["unit"], state["integration"], state["e2e"] }
    ')"
    pre="$(bash "$HOOK_DIR/analyze-precheck.sh" "$SCRATCH/spec.md" "$SCRATCH/diff.md" \
      --scratch "$SCRATCH" --test-scope "$scope_spec" --config "$CONFIG" \
      --findings-gate "$HOOK_DIR/findings-gate.sh" | grep '^agent=' | cut -d= -f2)"
    printf '%s\n' "$pre" > "$SCRATCH/analyze-decided.txt"
    if [ "$pre" = "run" ]; then
      cmd_dispatch "$SCRATCH" analyze Agent ship-analyze sonnet >/dev/null
      printf 'quality:analyze\n' >> "$SCRATCH/pending.txt"
      next_body_add "- Agent subagent_type=ship:ship-analyze (model sonnet), prompt: \"Task: $TASK_ID | Artifact language: $LANG_ | Storage mode: $STORE | Scratch dir: $SCRATCH | Test Scope: $scope_spec | Correlate script: $HOOK_DIR/analyze-correlate.sh | Findings gate script: $HOOK_DIR/findings-gate.sh | Read spec.md and diff.md from the scratch dir; your severities feed the gate; persist the drift report per storage mode.\""
      next_common_after
      next_emit "analyze" "dispatch" "$RUN" "correlation has gray-zone/gaps — analyze agent required"
    else
      next_consolidate "$SCRATCH" "$RUN" analyze
    fi
  fi
  if [ "$(head -1 "$SCRATCH/analyze-decided.txt" 2>/dev/null)" = "run" ]; then
    next_consolidate "$SCRATCH" "$RUN" analyze
  fi

  # --- gate-fix completion (snapshot diff → schedule reconciliation) -----------
  if [ -f "$SCRATCH/gate-fix-inflight.txt" ]; then
    rm -f "$SCRATCH/gate-fix-inflight.txt"
    bash "$HOOK_DIR/snapshot-files.sh" snapshot "$SCRATCH/post-fix-files.txt"
    bash "$HOOK_DIR/snapshot-files.sh" diff "$SCRATCH/pre-fix-files.txt" "$SCRATCH/post-fix-files.txt" \
      > "$SCRATCH/fix-changed-files.txt" || true
    if [ -s "$SCRATCH/fix-changed-files.txt" ]; then
      printf 'gate-fix\n' > "$SCRATCH/reconcile-source.txt"
    else
      # gates.md Edge case 1: the fix agent changed nothing — mark and proceed.
      printf 'warn-empty-fix\n' > "$SCRATCH/gate-resolved.txt"
    fi
  fi

  # --- reconciliation (fix touched source → surgical re-run) -------------------
  if [ -s "$SCRATCH/reconcile-source.txt" ]; then
    local changed="$SCRATCH/test-fix-changed-files.txt" rs rerun_p="" rerun_analyze="" depth_v2
    [ "$(head -1 "$SCRATCH/reconcile-source.txt")" = "gate-fix" ] && changed="$SCRATCH/fix-changed-files.txt"
    rs="$(bash "$HOOK_DIR/rerun-scope.sh" "$changed" "$SCRATCH/drift-findings.json" --config "$CONFIG" 2>/dev/null || true)"
    rm -f "$SCRATCH/reconcile-source.txt"
    depth_v2="$(grep '^depth=' "$SCRATCH/verify-a.txt" 2>/dev/null | sed 's/^depth=//')"
    # Only phases that actually ran this pipeline can re-run — rerun-scope has
    # no notion of profile/config enablement, so intersect with verify-a's set.
    local p2 ran_quality
    ran_quality="$(grep '^quality=' "$SCRATCH/verify-a.txt" 2>/dev/null | sed 's/^quality=//')"
    for p2 in perf security review analyze; do
      printf '%s' "$ran_quality" | grep -qw "$p2" || continue
      if printf '%s' "$rs" | grep -qE "\"$p2\":\{\"rerun\":true"; then
        rerun_p="$rerun_p $p2"
      fi
    done
    if [ -n "${rerun_p# }" ]; then
      RUN=$((RUN + 1))
      printf '%s\n' "$RUN" > "$SCRATCH/run-number.txt"
      for p2 in ${rerun_p# }; do
        rm -f "$SCRATCH/phase-status-$p2.md"
        if [ "$p2" = "analyze" ]; then
          rm -f "$SCRATCH/analyze-decided.txt"
          rerun_analyze="1"
        else
          next_quality_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "$STORE" "$p2" "${depth_v2:-flat}"
          printf 'quality:%s\n' "$p2" >> "$SCRATCH/pending.txt"
        fi
      done
      if [ -n "$NEXT_BODY" ]; then
        next_body_add "The fix changed source files — surgical re-run of the phases above (notes: re-run cirúrgico)."
        next_common_after
        next_emit "verify-rerun" "dispatch" "$RUN" "surgical re-run after fix"
      fi
      if [ -n "$rerun_analyze" ]; then
        next_body_add "The fix changed source files — analyze must re-correlate. Run: bash \"$HOOK_DIR/pipeline.sh\" next <task-id>"
        next_emit "verify-rerun" "work" "$RUN" "surgical re-run: analyze re-correlation"
      fi
    fi
  fi

  # --- gate --------------------------------------------------------------------
  if [ ! -f "$SCRATCH/gate-resolved.txt" ]; then
    next_consolidate "$SCRATCH" "$RUN" perf security review analyze test test-generate
    local g_out g_rc=0 g_decision g_action
    set +e
    g_out="$(run_gate "$SCRATCH" --config "$CONFIG" 2>&1)"
    g_rc=$?
    set -e
    if [ "$g_rc" -gt 2 ] || ! printf '%s' "$g_out" | grep -q '^decision='; then
      printf '%s\n' "$g_out" >&2
      exit 1
    fi
    g_decision="$(printf '%s\n' "$g_out" | grep '^decision=' | cut -d= -f2)"
    g_action="$(printf '%s\n' "$g_out" | grep '^action=' | cut -d= -f2)"
    if [ "$g_decision" = "PASS" ]; then
      printf 'PASS\n' > "$SCRATCH/gate-resolved.txt"
    else
      local choice="$ANSWER"
      [ -z "$choice" ] && [ "$g_action" != "ask" ] && choice="$g_action"
      case "$choice" in
        fix)
          local fx_rc=0
          set +e
          ( cmd_iter "$SCRATCH" fix --max 3 ) >/dev/null
          fx_rc=$?
          set -e
          if [ "$fx_rc" -eq 2 ]; then
            next_body_add "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
            next_emit "gate" "stop" "$RUN" "fix iteration limit reached"
          fi
          bash "$HOOK_DIR/snapshot-files.sh" snapshot "$SCRATCH/pre-fix-files.txt"
          touch "$SCRATCH/gate-fix-inflight.txt"
          next_fix_dispatch "$SCRATCH" "$TASK_ID" "$LANG_" "gate ($g_decision)" "$SCRATCH/phase-status.md + the per-phase findings files in $SCRATCH"
          next_common_after
          next_emit "gate-fix" "dispatch" "$RUN" "gate $g_decision — dispatching fix agent"
          ;;
        defer|pass)
          printf '%s deferred\n' "$g_decision" > "$SCRATCH/gate-resolved.txt"
          ;;
        *)
          next_body_add "Gate decision: $g_decision. Present the findings to the user in the artifact language (lazy-load per $HOOK_DIR/../patterns/lazy-load-findings.md; register tracking per storage mode — Linear sub-issues or tracking.md)."
          if [ "$g_decision" = "FAIL" ]; then
            next_body_add "Options: fix now | defer (proceed registering pending findings). Re-run next with --answer fix | --answer defer."
          else
            next_body_add "Options: fix now | pass (proceed). Re-run next with --answer fix | --answer pass."
          fi
          next_emit "gate" "ask" "$RUN" "gate $g_decision — user decision required"
          ;;
      esac
    fi
  fi

  # --- homolog ------------------------------------------------------------------
  if [ "$(phase_toggle "$CONFIG" homolog)" != "disabled" ] && [ ! -f "$SCRATCH/homolog-approved.txt" ]; then
    if [ "$ANSWER" = "approved" ]; then
      printf 'approved\n' > "$SCRATCH/homolog-approved.txt"
    else
      if ! next_dispatched "$SCRATCH" homolog; then
        cmd_dispatch "$SCRATCH" homolog Skill ship:homolog sonnet >/dev/null
      fi
      next_body_add "Invoke ship:homolog via the Skill tool — same context, NOT forked, never Agent. Args: \"Task: $TASK_ID | Artifact language: $LANG_ | Storage mode: $STORE | Scratch dir: $SCRATCH | Consolidate findings from phase-status.md and present for acceptance\"."
      next_body_add "MANDATORY STOP while homolog awaits the user. On approval, run: bash \"$HOOK_DIR/pipeline.sh\" next <task-id> --answer approved. On adjustment requests, apply them and re-invoke ship:homolog first."
      next_emit "homolog" "work" "$RUN" "awaiting user acceptance"
    fi
  fi

  # --- done ---------------------------------------------------------------------
  local timings
  timings="$(cmd_report_timings "$SCRATCH" 2>/dev/null || true)"
  if [ "$STORE" = "linear" ]; then
    next_body_add "Verify the Linear lifecycle: resolve the completed state per $HOOK_DIR/../patterns/linear-status.md (never hardcode), confirm state.type == \"completed\" and that the quality-report comment exists."
  else
    next_body_add "Write report-$TASK_ID.md under ship/changes/<feature>/ and mark the task done in tasks.md."
  fi
  next_body_add "Surface the per-phase wall-clock to the user:"
  next_body_add "$timings"
  next_body_add "Then inform: task complete — run /ship:pr when ready. NEVER auto-invoke /ship:pr. Multi-task: ask to continue with the next task."
  next_emit "done" "done" "$RUN" "pipeline complete"
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  next)
    cmd_next "$@" ;;
  init)
    cmd_init "$@" ;;
  dispatch)
    cmd_dispatch "$@" ;;
  complete)
    cmd_complete "$@" ;;
  gate)
    run_gate "$@" ;;
  rows)
    cmd_rows "$@" ;;
  iter)
    cmd_iter "$@" ;;
  report-timings)
    cmd_report_timings "$@" ;;
  post-develop)
    cmd_post_develop "$@" ;;
  *)
    usage
    exit 1 ;;
esac
