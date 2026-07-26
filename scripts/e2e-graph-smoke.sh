#!/usr/bin/env bash
# e2e-graph-smoke.sh — live, headless end-to-end smoke test of Ship's work graph.
#
# Sibling of e2e-smoke.sh, which proves the single-task pipeline. This one proves
# the COMPOSITION the unit tests cannot: /ship:spec → /ship:graph → per-node
# /ship:run in isolated workspaces → poll → seal → merge node → done.
#
# Every individual mechanism has unit coverage; what has none is the whole loop
# running against a real LLM in real workspaces. That is the only way to catch a
# node that lands with an empty commit, a merge that integrates nothing, or a
# graph that waits forever on a worker that already finished.
#
# Usage:
#   scripts/e2e-graph-smoke.sh [--fixture calculator|calculator-split]
#                              [--driver local|orca] [--max-in-flight N] [--keep]
#
# Requires: `claude` on PATH, Node.js. `--driver orca` also needs the orca CLI
# and registers the throwaway repo with it (removed again on exit).
# Costs tokens and takes several minutes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/ship"

FIXTURE=calculator
DRIVER=local
MAX_IN_FLIGHT=2
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)       FIXTURE="$2"; shift 2;;
    --driver)        DRIVER="$2"; shift 2;;
    --max-in-flight) MAX_IN_FLIGHT="$2"; shift 2;;
    --keep)          KEEP=1; shift;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

command -v claude >/dev/null || { echo "✗ claude CLI not found on PATH"; exit 1; }
command -v node   >/dev/null || { echo "✗ node not found on PATH"; exit 1; }
[ "$DRIVER" = "orca" ] && { command -v orca >/dev/null || { echo "✗ orca CLI not found on PATH"; exit 1; }; }

( cd "$PLUGIN" && npm run build >/dev/null 2>&1 ) || { echo "✗ plugin build failed"; exit 1; }

TMP="$(mktemp -d)"
ORCA_REPO_ID=""
GRAPH_REPO_ARG=""
cleanup() {
  # driver-local puts node workspaces beside the repo, on purpose (nesting them
  # inside would put extra checkouts in the tree the merge node tests over).
  rm -rf "$TMP/../.ship-graph" 2>/dev/null
  if [ -n "$ORCA_REPO_ID" ]; then
    orca worktree list --repo "id:$ORCA_REPO_ID" --json 2>/dev/null \
      | grep -oE '"[^"]+::[^"]+"' | tr -d '"' | sort -u \
      | while IFS= read -r wid; do orca worktree rm --worktree "id:$wid" --force --json >/dev/null 2>&1; done
    # There is no `orca repo rm`; setup-delete is the closest de-registration.
    # If it fails the entry lingers pointing at a deleted path — say so rather
    # than leaving the user to find it.
    orca project setup-delete --setup "$ORCA_REPO_ID" --json >/dev/null 2>&1 \
      || echo "  note: throwaway repo $ORCA_REPO_ID is still registered with orca — remove it in the app"
  fi
  [ "$KEEP" -eq 1 ] && echo "kept: $TMP" || rm -rf "$TMP"
}
trap cleanup EXIT

echo "Ship GRAPH E2E smoke — fixture=$FIXTURE driver=$DRIVER max-in-flight=$MAX_IN_FLIGHT"
echo "  workdir: $TMP"
echo "  plugin:  $PLUGIN"
echo

cd "$TMP"
git init -q
git config user.email e2e@ship.test
git config user.name "Ship E2E"

cat > package.json <<'JSON'
{ "name": "ship-graph-e2e", "version": "0.0.0", "type": "module", "scripts": { "test": "node --test" } }
JSON

printf '.context/\nnode_modules/\n' > .gitignore

mkdir -p ship
cat > ship/config.md <<'CFG'
# Ship Config

## Project
- Name: ship-graph-e2e
- Type: backend

## Linear Integration
- Configured: no

## Stack
- Language: JavaScript
- Runtime: Node.js
- Framework: none
- Test Framework: node --test
- Package Manager: npm

## Gate Behavior
# defer/pass so a non-deterministic gate never blocks the headless run.
- on_fail: defer
- on_warn: pass
- on_fail_rerun: surgical

## Pipeline Profile
- profile: standard

## Pipeline Phases
- dev: enabled
- test: enabled
- perf: disabled
- security: disabled
- review: disabled
- homolog: enabled
- pr: disabled

## Test Scope
- unit: enabled
- integration: disabled
- e2e: disabled

## Conventions
- Artifact language: en
- Prompt language: en
- Code language: English
- Commit style: Conventional Commits
CFG

git add -A
git commit -qm "baseline: empty fixture project"
git branch -M main
git update-ref refs/remotes/origin/main main
git checkout -q -b feature/graph-e2e

case "$FIXTURE" in
  calculator)
    DESC="Build a tiny pure-function calculator as ES modules with no external dependencies. src/add.js exports add. src/subtract.js exports subtract. src/multiply.js exports multiply. src/divide.js exports divide, which throws an Error on divide-by-zero. Each of the four is an independent file with no imports between them, and each gets its own unit test file using node:test + node:assert. Keep every file under 30 lines. No UI." ;;
  calculator-split)
    DESC="Build a tiny calculator as ES modules with no external dependencies, in two independent layers. src/ops.js exports add, subtract, multiply and divide as pure functions; divide throws on divide-by-zero. src/format.js exports formatResult(n) returning a string with at most two decimals. The two files must not import each other. Each gets its own unit test file using node:test + node:assert. Keep every file under 40 lines. No UI." ;;
  *) echo "unknown fixture: $FIXTURE"; exit 2;;
esac

TO=""
if command -v timeout >/dev/null; then TO="timeout 2400"
elif command -v gtimeout >/dev/null; then TO="gtimeout 2400"; fi
run_claude() { $TO claude --print --dangerously-skip-permissions --plugin-dir "$PLUGIN" "$1"; }

if [ "$DRIVER" = "orca" ]; then
  echo "▶ registering the throwaway repo with the workspace runtime ..."
  # Scope the match to the payload: every orca response opens with a
  # request-envelope "id" that is also a 36-char uuid, so an unscoped grep
  # silently returns the envelope and every later call fails repo_not_found.
  ORCA_REPO_ID="$(orca repo add --path "$TMP" --json 2>/dev/null \
    | sed -n '/"result"/,$p' \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-f-]{36}"' | head -1 \
    | sed -E 's/.*"([0-9a-f-]{36})".*/\1/')"
  [ -n "$ORCA_REPO_ID" ] || { echo "✗ could not register the repo with orca"; exit 1; }
  # Resolve it before using it. An id that does not resolve here is a wrong id,
  # and finding that out now beats finding it out from a dispatch failure.
  orca repo show --repo "id:$ORCA_REPO_ID" --json >/dev/null 2>&1 \
    || { echo "✗ registered repo id $ORCA_REPO_ID does not resolve"; exit 1; }
  echo "  repo id: $ORCA_REPO_ID"
  GRAPH_REPO_ARG="--repo $ORCA_REPO_ID"
  # Workers are separate claude sessions the runtime launches; without this they
  # resolve the INSTALLED Ship plugin, not the build under test, and the run
  # silently measures the released version instead.
  export SHIP_WORKER_COMMAND="claude --dangerously-skip-permissions --plugin-dir $PLUGIN"
  echo "  worker command: $SHIP_WORKER_COMMAND"
fi

echo "▶ /ship:spec ..."
run_claude "/ship:spec $DESC" || { echo "✗ spec invocation failed"; exit 1; }

FEATURE="$(ls ship/changes 2>/dev/null | head -1 || true)"
[ -n "$FEATURE" ] || { echo "✗ spec produced no ship/changes/<feature> workspace"; exit 1; }
echo "  feature: $FEATURE"

TASK_COUNT="$(grep -cE '^###+[[:space:]]+TASK-' "ship/changes/$FEATURE/tasks.md" 2>/dev/null || echo 0)"
echo "  tasks decomposed: $TASK_COUNT"

echo "▶ /ship:graph $FEATURE --driver $DRIVER --max-in-flight $MAX_IN_FLIGHT $GRAPH_REPO_ARG ..."
run_claude "/ship:graph $FEATURE --driver $DRIVER --max-in-flight $MAX_IN_FLIGHT $GRAPH_REPO_ARG" \
  || echo "  (graph returned non-zero — checking artifacts anyway)"

# --- Assertions ---------------------------------------------------------------
echo
fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

GDIR="$(find .context/ship-graph -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
if [ -z "$GDIR" ]; then
  bad "no .context/ship-graph/<feature>/ produced — the graph never initialized"
  echo -e "\033[31mGRAPH E2E smoke: FAIL\033[0m"
  exit 1
fi
ok "graph dir: $GDIR"

for f in graph.json nodes.tsv meta.tsv; do
  [ -s "$GDIR/$f" ] && ok "graph artifact: $f" || bad "missing/empty graph artifact: $f"
done

NODES="$(awk -F'\t' '{ print $1 }' "$GDIR/nodes.tsv" 2>/dev/null)"
NODE_N="$(printf '%s\n' "$NODES" | sed '/^$/d' | wc -l | tr -d ' ')"
[ "$NODE_N" -ge 1 ] && ok "graph built $NODE_N node(s) from tasks.md" || bad "graph built no nodes"

# Every node integrated. This is the whole point: not "ran", but "landed, sealed,
# merged and marked done".
NOT_DONE="$(awk -F'\t' '$6 != "done" { print $1 " (" $6 ")" }' "$GDIR/nodes.tsv" | tr '\n' ' ')"
[ -z "$NOT_DONE" ] && ok "every node reached done" || bad "nodes not integrated: $NOT_DONE"

INTEG="$(awk -F'\t' '$1 == "integration_status" { print $2 }' "$GDIR/meta.tsv" 2>/dev/null)"
[ "$INTEG" = "green" ] && ok "integration status: green" || bad "integration status: ${INTEG:-unset}"

# The bug this test exists for: a node can look green while its branch carries no
# commit, so the merge integrates nothing.
sealed_ok=1
for n in $NODES; do
  [ -n "$n" ] || continue
  br="$(awk -F'\t' -v id="$n" '$1 == id { print $8 }' "$GDIR/nodes.tsv")"
  [ -n "$br" ] || { bad "node $n never recorded a branch"; sealed_ok=0; continue; }
  c="$(git rev-list --count "main..$br" 2>/dev/null || echo 0)"
  [ "${c:-0}" -ge 1 ] || { bad "node $n branch $br has no commit — the merge integrated nothing"; sealed_ok=0; }
done
[ "$sealed_ok" -eq 1 ] && ok "every node's workspace was sealed into a real commit"

# Deferred homolog: a report per node, and no node stopped for its own approval.
for n in $NODES; do
  [ -n "$n" ] || continue
  wt="$(awk -F'\t' -v id="$n" '$1 == id { print $7 }' "$GDIR/nodes.tsv")"
  [ -n "$wt" ] || continue
  if [ -s "$wt/.context/ship-run/$n/homolog-report.md" ]; then
    ok "deferred homolog report: $n"
  else
    bad "no homolog-report.md for $n (defer did not take)"
  fi
  am="$(head -1 "$wt/.context/ship-run/$n/homolog-approved.txt" 2>/dev/null || true)"
  [ "$am" = "deferred" ] && ok "node $n was auto-approved as deferred" \
    || bad "node $n homolog-approved.txt = '${am:-missing}' (expected 'deferred')"
done

# The integrated result must exist and actually work on the base branch.
SRC="$(git ls-files 'src/*' | grep -vE '\.(test|spec)\.' || true)"
TST="$(git ls-files 'src/*' 'test/*' '__tests__/*' | grep -E '\.(test|spec)\.' || true)"
[ -n "$SRC" ] && ok "source on the base branch: $(echo "$SRC" | tr '\n' ' ')" || bad "no source merged into the base branch"
[ -n "$TST" ] && ok "tests on the base branch: $(echo "$TST" | tr '\n' ' ')" || bad "no tests merged into the base branch"

if node --test >/tmp/ship-graph-e2e-test.log 2>&1; then
  ok "integrated suite passes (node --test)"
else
  bad "integrated suite FAILED"
  sed 's/^/    /' /tmp/ship-graph-e2e-test.log | tail -25
fi

echo
echo "  --- graph status ---"
bash "$PLUGIN/hooks/graph.sh" status 2>/dev/null | sed 's/^/    /'
echo "  --- graph log ---"
sed 's/^/    /' "$GDIR/graph-log.md" 2>/dev/null | tail -30

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mGRAPH E2E smoke: PASS\033[0m"; else echo -e "\033[31mGRAPH E2E smoke: FAIL\033[0m"; fi
exit "$fail"
