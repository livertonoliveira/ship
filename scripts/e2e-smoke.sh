#!/usr/bin/env bash
# e2e-smoke.sh — live, headless end-to-end smoke test of the Ship pipeline.
#
# Spins up a throwaway git project, seeds a Local-mode ship/config.md, then drives
# the REAL pipeline against the LOCAL plugin build (plugins/ship) via the headless
# `claude --print --plugin-dir` CLI: /ship:spec → /ship:run (dev→test→perf→
# security→review→analyze→homolog). Asserts structural invariants and runs the
# generated test suite. Ship is LLM-driven, so this validates that the machinery
# produces the right artifacts and passing tests — not exact code.
#
# Usage:
#   scripts/e2e-smoke.sh [--fixture calculator|tictactoe] [--scope full|lite] [--keep]
#
# Requires: the `claude` CLI on PATH, Node.js (for the zero-dep `node --test` runner).
# Costs tokens and takes several minutes. Run before releases / after big changes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/ship"

FIXTURE=calculator
SCOPE=full
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fixture) FIXTURE="$2"; shift 2;;
    --scope)   SCOPE="$2"; shift 2;;
    --keep)    KEEP=1; shift;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

command -v claude >/dev/null || { echo "✗ claude CLI not found on PATH"; exit 1; }
command -v node   >/dev/null || { echo "✗ node not found on PATH"; exit 1; }

# Build the plugin from current src/ so we test exactly what we just changed.
( cd "$PLUGIN" && npm run build >/dev/null 2>&1 ) || { echo "✗ plugin build failed"; exit 1; }

TMP="$(mktemp -d)"
cleanup() { [ "$KEEP" -eq 1 ] && echo "kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

echo "Ship E2E smoke — fixture=$FIXTURE scope=$SCOPE"
echo "  workdir: $TMP"
echo "  plugin:  $PLUGIN"
echo

# --- Fixture project ----------------------------------------------------------
cd "$TMP"
git init -q
git config user.email e2e@ship.test
git config user.name "Ship E2E"

cat > package.json <<'JSON'
{ "name": "ship-e2e", "version": "0.0.0", "type": "module", "scripts": { "test": "node --test" } }
JSON

# Mirror a real consuming project: the pipeline scratch dir is never committed.
printf '.context/\nnode_modules/\n' > .gitignore

# Phases for the chosen scope. Full = everything except pr (we stop at homolog).
if [ "$SCOPE" = "lite" ]; then
  PHASES=$'- dev: enabled\n- test: enabled\n- perf: disabled\n- security: disabled\n- review: disabled\n- analyze: disabled\n- homolog: enabled\n- pr: disabled'
else
  PHASES=$'- dev: enabled\n- test: enabled\n- perf: enabled\n- security: enabled\n- review: enabled\n- analyze: enabled\n- homolog: enabled\n- pr: disabled'
fi

mkdir -p ship
cat > ship/config.md <<CFG
# Ship Config

## Project
- Name: ship-e2e
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
# defer/pass so a non-deterministic gate never blocks the headless run;
# we inspect phase-status.md for the actual gate outcomes instead.
- on_fail: defer
- on_warn: pass
- on_fail_rerun: surgical

## Pipeline Profile
- profile: standard

## Pipeline Phases
$PHASES

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
# Fake origin/main so the pipeline's `git merge-base origin/main HEAD` resolves
# without a real remote.
git update-ref refs/remotes/origin/main main
git checkout -q -b feature/e2e

# --- Fixture prompt -----------------------------------------------------------
case "$FIXTURE" in
  calculator)
    DESC="Build a tiny pure-function calculator at src/calculator.js (ES module) exporting add, subtract, multiply, and divide. divide must throw an Error on divide-by-zero. Add unit tests with Node's built-in node:test + node:assert. Keep the whole change under 80 lines. No UI, no external dependencies." ;;
  tictactoe)
    DESC="Build tiny tic-tac-toe game logic at src/ttt.js (ES module): createBoard() returning an empty 3x3 board, applyMove(board,row,col,player), and detectWinner(board) returning 'X' | 'O' | 'draw' | null. Add unit tests with node:test + node:assert. Keep it under 120 lines. No UI, no external dependencies." ;;
  *) echo "unknown fixture: $FIXTURE"; exit 2;;
esac

# Portable timeout: GNU `timeout`, Homebrew `gtimeout`, or none (run directly).
# Plain string (not an array) to stay compatible with macOS bash 3.2 under `set -u`.
TO=""
if command -v timeout >/dev/null; then TO="timeout 1200"
elif command -v gtimeout >/dev/null; then TO="gtimeout 1200"; fi
run_claude() { $TO claude --print --dangerously-skip-permissions --plugin-dir "$PLUGIN" "$1"; }

echo "▶ /ship:spec ..."
run_claude "/ship:spec $DESC" || { echo "✗ spec invocation failed"; exit 1; }

FEATURE="$(ls ship/changes 2>/dev/null | head -1 || true)"
[ -n "$FEATURE" ] || { echo "✗ spec produced no ship/changes/<feature> workspace"; exit 1; }
echo "  feature: $FEATURE"

echo "▶ /ship:run --project $FEATURE ..."
run_claude "/ship:run --project $FEATURE" || echo "  (run returned non-zero — checking artifacts anyway)"

# --- Assertions ---------------------------------------------------------------
echo
fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

SCR="$(find .context/ship-run -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
if [ -n "$SCR" ]; then
  ok "scratch dir: $SCR"
  for f in diff.md spec.md design.md phase-status.md; do
    if [ -s "$SCR/$f" ]; then ok "scratch artifact: $f"; else bad "missing/empty scratch artifact: $f"; fi
  done
  # plan.md exists only when the planner runs. For single-module tasks the
  # pipeline legitimately skips it (run/SKILL.md §1.9), logging `plan ... skipped`
  # in dispatch-log.md — so require plan.md only when the planner actually ran.
  if grep -qE '^\| *plan .*\| *skipped ' "$SCR/dispatch-log.md" 2>/dev/null; then
    ok "planner skipped (single-module task) — plan.md not expected"
  elif [ -s "$SCR/plan.md" ]; then
    ok "scratch artifact: plan.md"
  else
    bad "missing/empty scratch artifact: plan.md (planner ran but wrote none)"
  fi
else
  bad "no .context/ship-run/<task>/ scratch dir produced"
fi

# Source + test files in the working tree
CHANGED="$(git diff --name-only origin/main 2>/dev/null || true)"
TEST_RE='\.(test|spec)\.[jt]sx?$|(^|/)(test|tests|__tests__)/'
SRC_FILES="$(echo "$CHANGED" | grep -E '^src/' | grep -vE "$TEST_RE" || true)"
TEST_FILES="$(echo "$CHANGED" | grep -E "$TEST_RE" || true)"
[ -n "$SRC_FILES" ]  && ok "source produced: $(echo "$SRC_FILES" | tr '\n' ' ')" || bad "no source files produced"
[ -n "$TEST_FILES" ] && ok "tests produced: $(echo "$TEST_FILES" | tr '\n' ' ')" || bad "no test files produced"

# The generated suite must actually pass
if node --test >/tmp/ship-e2e-test.log 2>&1; then ok "generated test suite passes (node --test)"; else bad "generated test suite FAILED"; sed 's/^/    /' /tmp/ship-e2e-test.log | tail -20; fi

# Phase coverage in the trace
if [ -n "${SCR:-}" ] && [ -f "$SCR/phase-status.md" ]; then
  expect=(dev test); [ "$SCOPE" = full ] && expect=(dev test perf security review analyze)
  for ph in "${expect[@]}"; do
    grep -qiE "^\| *$ph " "$SCR/phase-status.md" && ok "phase ran: $ph" || bad "phase missing from trace: $ph"
  done
  echo "  --- phase-status.md ---"; sed 's/^/    /' "$SCR/phase-status.md"
fi

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mE2E smoke: PASS\033[0m"; else echo -e "\033[31mE2E smoke: FAIL\033[0m"; fi
exit "$fail"
