#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pipeline.sh <subcommand> [args...]" >&2
  echo "  init      <task-id> [--mode check|fresh|resume] [--config <path>]" >&2
  echo "  dispatch  <scratch-dir> <phase> <tool> <name> <model>" >&2
  echo "  complete  <scratch-dir> <run-number> <phase>..." >&2
  echo "  gate      <scratch-dir> [--config <path>]" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

KNOWN_PHASES="plan dev test perf security review analyze"

is_known_phase() {
  local phase="$1"
  local candidate
  for candidate in $KNOWN_PHASES; do
    [ "$candidate" = "$phase" ] && return 0
  done
  return 1
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

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '| %s | %s | %s | %s | %s |\n' "$phase" "$tool" "$name" "$model" "$ts" >> "$scratch_dir/dispatch-log.md"
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

gate_usage() {
  echo "usage: pipeline.sh gate <scratch-dir> [--config <path>]" >&2
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
    exec bash "$HOOK_DIR/run-init.sh" "$@" ;;
  dispatch)
    cmd_dispatch "$@" ;;
  complete)
    cmd_complete "$@" ;;
  gate)
    run_gate "$@" ;;
  *)
    usage
    exit 1 ;;
esac
