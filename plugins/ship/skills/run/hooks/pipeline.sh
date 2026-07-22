#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pipeline.sh <subcommand> [args...]" >&2
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
REQUIRED_HOOKS="capture-diff.sh diff-classify.sh snapshot-files.sh status-consolidate.sh evidence-gate.sh"

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

KNOWN_PHASES="plan dev test perf security review analyze"

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
      phase = $2; tool = $3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", phase)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", tool)
      if (phase != "" && phase != "Phase" && phase !~ /^-+$/ && tool != "skipped") print phase
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

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
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
