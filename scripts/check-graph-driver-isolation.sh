#!/usr/bin/env bash
# check-graph-driver-isolation.sh
#
# The work graph's value depends on graph.sh staying runtime-agnostic: swapping
# the workspace runtime must be swapping one driver file, never editing the
# scheduler. That property is invisible at review time — a single `orca …` call
# added to graph.sh to "just get the path" looks harmless and quietly welds the
# graph to one runtime. This guard makes it fail loudly instead.
#
# Three assertions:
#   1. src/hooks/graph.sh names no workspace runtime.
#   2. src/skills/graph/SKILL.md names no workspace runtime either (a skill that
#      hardcodes one re-creates the coupling one level up).
#   3. every src/hooks/driver-*.sh implements every verb in the contract.
#
# Usage: ./scripts/check-graph-driver-isolation.sh
# Exit code 0 = clean; exit code 1 = violation(s) found.

set -euo pipefail

REPO_ROOT="${GRAPH_ISOLATION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GRAPH_SH="${REPO_ROOT}/src/hooks/graph.sh"
GRAPH_SKILL="${REPO_ROOT}/src/skills/graph/SKILL.md"
HOOKS_DIR="${REPO_ROOT}/src/hooks"

# Workspace runtimes a driver may talk to. Deliberately not a list of every
# binary on earth — these are the ones a graph would plausibly reach for.
RUNTIME_PATTERN='\b(orca|orca-ide|codex|conductor|tmux|docker|kubectl|devcontainer)\b'
VERBS=(dispatch collect wait ask stop probe)

VIOLATIONS=0

echo "Checking that graph.sh stays driver-agnostic..."
echo ""

if [[ ! -f "$GRAPH_SH" ]]; then
  echo "VIOLATION: $GRAPH_SH not found"
  exit 1
fi

hits="$(grep -nEi "$RUNTIME_PATTERN" "$GRAPH_SH" || true)"
if [[ -n "$hits" ]]; then
  echo "VIOLATION: src/hooks/graph.sh references a workspace runtime directly"
  echo "$hits" | sed 's/^/  /'
  echo ""
  VIOLATIONS=$((VIOLATIONS + 1))
fi

if [[ -f "$GRAPH_SKILL" ]]; then
  # The skill may name a driver as a configurable value (--driver orca); what it
  # must not do is invoke the runtime itself.
  skill_hits="$(grep -nEi "$RUNTIME_PATTERN" "$GRAPH_SKILL" \
    | grep -vE -- '--driver|driver=|`orca`|driver <d>' || true)"
  if [[ -n "$skill_hits" ]]; then
    echo "VIOLATION: src/skills/graph/SKILL.md invokes a workspace runtime directly"
    echo "$skill_hits" | sed 's/^/  /'
    echo ""
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
fi

if ! grep -q 'driver-\$driver\.sh\|driver-\$DRIVER\.sh' "$GRAPH_SH"; then
  echo "VIOLATION: src/hooks/graph.sh no longer resolves its driver by name"
  echo "  expected a \"driver-\$driver.sh\" reference — without it the adapter seam is gone"
  echo ""
  VIOLATIONS=$((VIOLATIONS + 1))
fi

found_driver=0
for driver in "$HOOKS_DIR"/driver-*.sh; do
  [[ -f "$driver" ]] || continue
  found_driver=1
  name="$(basename "$driver")"
  for verb in "${VERBS[@]}"; do
    if ! grep -qE "^ *${verb}\)|^verb_${verb}\(\)" "$driver"; then
      echo "VIOLATION: src/hooks/${name} does not implement the '${verb}' verb"
      echo ""
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done
done

if [[ "$found_driver" -eq 0 ]]; then
  echo "VIOLATION: no src/hooks/driver-*.sh found — graph.sh has nothing to dispatch through"
  echo ""
  VIOLATIONS=$((VIOLATIONS + 1))
fi

if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "OK — graph.sh names no runtime, and every driver implements every verb."
  exit 0
else
  echo "FAILED — ${VIOLATIONS} violation(s)."
  echo ""
  echo "graph.sh must reach the workspace runtime only through driver-<name>.sh's"
  echo "five verbs (dispatch/collect/wait/ask/stop). Runtime-specific code belongs in a"
  echo "driver; if a driver cannot express what you need, extend the verb contract"
  echo "for every driver rather than special-casing one runtime in the scheduler."
  exit 1
fi
