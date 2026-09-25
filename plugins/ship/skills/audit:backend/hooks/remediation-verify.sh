#!/usr/bin/env bash

# remediation-verify.sh <scratch-dir> [--config <path>]
#
# Score the confirmation pass over a remediation batch and rewrite the affected
# phase rows from its verdicts.
#
# This is what replaces the post-fix surgical re-run. That re-run re-dispatched
# perf/security/review as fresh OPEN-ENDED audits of code the fix had just
# written, and an open-ended audit of new code always finds new nits — which is
# why the gate loop never converged on its own and needed a cap, an identity
# ledger and a churn guard to stop it. A closed question set cannot mint a new
# finding, so the batch shrinks monotonically and the loop terminates by
# construction.
#
# Reads <scratch>/remediation-verify.md, one verdict per item:
#   - R1: resolved
#   - R3: unresolved — <reason>
# An item with no verdict counts as unresolved: silence is not evidence.
#
# Rewrites phase-status-<phase>.md for each finding-bearing phase, counting only
# the findings still unresolved. Deterministic items (typecheck/lint, suite,
# coverage) are not scored here — re-running the checks is the verdict.
#
# Prints: resolved=<n> unresolved=<n> unresolved_ids=<csv>

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scratch=""
config="ship/config.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    -*) echo "usage: remediation-verify.sh <scratch-dir> [--config <path>]" >&2; exit 1 ;;
    *)
      if [ -z "$scratch" ]; then scratch="$1"; else
        echo "usage: remediation-verify.sh <scratch-dir> [--config <path>]" >&2; exit 1
      fi
      shift ;;
  esac
done

if [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
  echo "usage: remediation-verify.sh <scratch-dir> [--config <path>]" >&2
  exit 1
fi

items="$scratch/remediation-items.txt"
verdicts="$scratch/remediation-verify.md"
[ -f "$items" ] || { echo "remediation-verify.sh: no remediation-items.txt in $scratch" >&2; exit 1; }

is_resolved() {
  local id="$1"
  [ -f "$verdicts" ] || return 1
  grep -qE "^[[:space:]]*[-*]?[[:space:]]*${id}[[:space:]]*:[[:space:]]*resolved([[:space:]]|$)" "$verdicts"
}

resolved_n=0
unresolved_n=0
unresolved_ids=""

# Per-phase severity tallies of the findings that survived the fix.
phases=""
while IFS='|' read -r id kind phase severity file slug; do
  [ -n "${id:-}" ] || continue
  [ "$kind" = "finding" ] || continue
  case " $phases " in *" $phase "*) ;; *) phases="$phases $phase" ;; esac
  if is_resolved "$id"; then
    resolved_n=$((resolved_n + 1))
    continue
  fi
  unresolved_n=$((unresolved_n + 1))
  unresolved_ids="${unresolved_ids:+$unresolved_ids,}$id"
  eval "c_${phase//-/_}_${severity}=\$(( \${c_${phase//-/_}_${severity}:-0} + 1 ))"
done < "$items"

for phase in $phases; do
  key="${phase//-/_}"
  eval "crit=\${c_${key}_critical:-0}; high=\${c_${key}_high:-0}; med=\${c_${key}_medium:-0}; low=\${c_${key}_low:-0}"
  bash "$HOOK_DIR/findings-gate.sh" "$phase" \
    --critical "$crit" --high "$high" --medium "$med" --low "$low" \
    --notes "após remediação" --scratch "$scratch" --config "$config" >/dev/null
done

printf 'resolved=%s\n' "$resolved_n"
printf 'unresolved=%s\n' "$unresolved_n"
printf 'unresolved_ids=%s\n' "$unresolved_ids"
