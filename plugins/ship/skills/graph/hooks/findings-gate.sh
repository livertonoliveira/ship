#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: findings-gate.sh <phase> (--findings <json> | --critical N --high N --medium N --low N) [options]" >&2
  echo "  --findings <file>   count severities from a JSON array of {\"severity\":...} objects" >&2
  echo "  --critical/--high/--medium/--low N   explicit finding counts (ignored when --findings is given)" >&2
  echo "  --files <str>       Files column value (default '-')" >&2
  echo "  --notes <str>       Notes column value (default empty)" >&2
  echo "  --scratch <dir>     write the row to <dir>/phase-status-<phase>.md" >&2
  echo "  --config <path>     config for Severity Overrides (default ship/config.md)" >&2
  echo "  --run <n>           Run column value (default literal '#<RUN>')" >&2
}

VALID_PHASES="dev test perf security review frontend-perf database backend"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_severity() {
  case "$1" in
    critical|high|medium|low) printf '%s' "$1"; return 0 ;;
    warn) printf '%s' "medium"; return 0 ;;
    *) return 1 ;;
  esac
}

count_from_json() {
  local file="$1" level="$2" n
  n="$( { grep -oE "\"severity\"[[:space:]]*:[[:space:]]*\"$level\"" "$file" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

# Apply the Severity Overrides for a single phase to the four count variables.
# Idempotent: the `from` bucket is emptied, so re-application is a no-op — this
# mirrors pipeline.sh's aggregate gate, which re-applies the same overrides.
apply_overrides() {
  local config="$1" phase="$2"
  [ -f "$config" ] || return 0

  local -a lines=()
  local line
  while IFS= read -r line; do
    lines+=("$line")
  done < <(awk '
    /^## Severity Overrides/ { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^-[[:space:]]*[A-Za-z0-9_-]+:/ { print }
  ' "$config")

  local entry p rest from to nf nt
  for entry in ${lines[@]+"${lines[@]}"}; do
    p="$(printf '%s\n' "$entry" | sed -E 's/^-[[:space:]]*([A-Za-z0-9_-]+):.*/\1/')"
    [ "$p" = "$phase" ] || continue
    rest="$(printf '%s\n' "$entry" | sed -E 's/^-[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*//')"
    from="$(trim "$(printf '%s' "$rest" | awk -F'→' '{print $1}')")"
    to="$(trim "$(printf '%s' "$rest" | awk -F'→' '{print $2}')")"
    nf="$(normalize_severity "$from")" || continue
    nt="$(normalize_severity "$to")" || continue
    [ "$nf" = "$nt" ] && continue

    local moved
    case "$nf" in
      critical) moved="$CRIT"; CRIT=0 ;;
      high) moved="$HIGH"; HIGH=0 ;;
      medium) moved="$MED"; MED=0 ;;
      low) moved="$LOW"; LOW=0 ;;
    esac
    case "$nt" in
      critical) CRIT=$((CRIT + moved)) ;;
      high) HIGH=$((HIGH + moved)) ;;
      medium) MED=$((MED + moved)) ;;
      low) LOW=$((LOW + moved)) ;;
    esac
  done
}

main() {
  local phase="" findings="" files="-" notes="" scratch="" config="ship/config.md" run="#<RUN>"
  CRIT="" HIGH="" MED="" LOW=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --findings) findings="$2"; shift 2 ;;
      --critical) CRIT="$2"; shift 2 ;;
      --high) HIGH="$2"; shift 2 ;;
      --medium) MED="$2"; shift 2 ;;
      --low) LOW="$2"; shift 2 ;;
      --files) files="$2"; shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      --scratch) scratch="$2"; shift 2 ;;
      --config) config="$2"; shift 2 ;;
      --run) run="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$phase" ]; then phase="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$phase" ]; then usage; exit 1; fi
  case " $VALID_PHASES " in
    *" $phase "*) ;;
    *) echo "findings-gate.sh: unknown phase: $phase" >&2; exit 1 ;;
  esac

  if [ -n "$findings" ]; then
    if [ ! -f "$findings" ]; then
      echo "findings-gate.sh: findings file not found: $findings" >&2
      exit 1
    fi
    CRIT="$(count_from_json "$findings" critical)"
    HIGH="$(count_from_json "$findings" high)"
    MED="$(count_from_json "$findings" medium)"
    LOW="$(count_from_json "$findings" low)"
  fi

  CRIT="${CRIT:-0}"; HIGH="${HIGH:-0}"; MED="${MED:-0}"; LOW="${LOW:-0}"
  local v
  for v in "$CRIT" "$HIGH" "$MED" "$LOW"; do
    case "$v" in
      *[!0-9]*|'') echo "findings-gate.sh: counts must be non-negative integers (got '$v')" >&2; exit 1 ;;
    esac
  done

  apply_overrides "$config" "$phase"

  local gate gate_lower
  if [ "$CRIT" -gt 0 ] || [ "$HIGH" -gt 0 ]; then
    gate="FAIL"; gate_lower="fail"
  elif [ "$MED" -gt 0 ]; then
    gate="WARN"; gate_lower="warn"
  else
    gate="PASS"; gate_lower="pass"
  fi

  local row
  row="$(printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |' \
    "$phase" "$run" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$files" "$gate_lower" \
    "$CRIT" "$HIGH" "$MED" "$LOW" "$notes")"

  if [ -n "$scratch" ]; then
    mkdir -p "$scratch"
    printf '%s\n' "$row" > "$scratch/phase-status-$phase.md"
  fi

  printf 'critical=%s\n' "$CRIT"
  printf 'high=%s\n' "$HIGH"
  printf 'medium=%s\n' "$MED"
  printf 'low=%s\n' "$LOW"
  printf 'gate=%s\n' "$gate"
  printf 'row=%s\n' "$row"
}

main "$@"
