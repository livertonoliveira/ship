#!/usr/bin/env bash
# e2e-smoke.sh — live, headless end-to-end smoke test of the Ship pipeline.
#
# Spins up a throwaway git project, seeds a Local-mode ship/config.md, then drives
# the REAL pipeline against the LOCAL plugin build (plugins/ship) via the headless
# `claude --print --plugin-dir` CLI: /ship:spec → /ship:run (dev→test→perf→
# security→review→homolog). Asserts structural invariants and runs the
# generated test suite. Ship is LLM-driven, so this validates that the machinery
# produces the right artifacts and passing tests — not exact code.
#
# Usage:
#   scripts/e2e-smoke.sh [--fixture calculator|tictactoe] [--scope full|lite]
#                        [--gate defer|fix] [--seed-defect] [--keep]
#
# --gate fix + --seed-defect is the only combination that reaches the remediation
# path with real agents: the fixture is clean enough that every gate passes, so
# on_fail: fix alone never fires. The defect is a real one (eval of external
# input) found by the real security worker, not a stubbed finding.
#
# Requires: the `claude` CLI on PATH, Node.js (for the zero-dep `node --test` runner).
# Costs tokens and takes several minutes. Run before releases / after big changes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/ship"

FIXTURE=calculator
SCOPE=full
GATE=defer
SEED_DEFECT=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)     FIXTURE="$2"; shift 2;;
    --scope)       SCOPE="$2"; shift 2;;
    --gate)        GATE="$2"; shift 2;;
    --seed-defect) SEED_DEFECT=1; shift;;
    --keep)        KEEP=1; shift;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done
case "$GATE" in
  defer) ON_FAIL=defer; ON_WARN=pass;;
  fix)   ON_FAIL=fix;   ON_WARN=fix;;
  *) echo "unknown --gate: $GATE (defer|fix)"; exit 2;;
esac

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
  PHASES=$'- dev: enabled\n- test: enabled\n- perf: disabled\n- security: disabled\n- review: disabled\n- homolog: enabled\n- pr: disabled'
else
  PHASES=$'- dev: enabled\n- test: enabled\n- perf: enabled\n- security: enabled\n- review: enabled\n- homolog: enabled\n- pr: disabled'
fi

# A real, dependency-free lint rule the generated code satisfies: no debug
# logging and no `var` in source. Green on correct output, so it exercises the
# static-command injection into develop without making the gate flaky.
cat > lint.sh <<'LINT'
#!/usr/bin/env bash
hits="$(grep -rnE '(^|[^.[:alnum:]_])var[[:space:]]|console\.log' src 2>/dev/null || true)"
if [ -n "$hits" ]; then
  printf 'lint: banned construct (var / console.log)\n%s\n' "$hits"
  exit 1
fi
exit 0
LINT
chmod +x lint.sh

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
- Lint: $TMP/lint.sh

## Gate Behavior
# Default defer/pass so a non-deterministic gate never blocks the headless run;
# we inspect phase-status.md for the actual gate outcomes instead. --gate fix
# swaps in the remediation path on purpose.
- on_fail: $ON_FAIL
- on_warn: $ON_WARN

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

if [ "$SEED_DEFECT" -eq 1 ]; then
  echo "▶ seeding a real defect into the diff ..."
  mkdir -p src
  cat > src/evaluate.js <<'DEF'
export function evaluate(expression) {
  return eval(expression)
}
DEF
  git add -A && git commit -qm "feat: expression evaluation helper"
  echo "  seeded: src/evaluate.js (eval of external input)"
fi

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
  # plan.md exists only when the planner runs. A trivial/minor baseline diff
  # legitimately skips it, logging `plan ... skipped` in dispatch-log.md — so
  # require plan.md only when the planner actually ran.
  if grep -qE '^\| *plan .*\| *skipped ' "$SCR/dispatch-log.md" 2>/dev/null; then
    ok "planner skipped (trivial/minor baseline) — plan.md not expected"
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
  expect=(dev test); [ "$SCOPE" = full ] && expect=(dev test perf security review)
  for ph in "${expect[@]}"; do
    grep -qiE "^\| *$ph " "$SCR/phase-status.md" && ok "phase ran: $ph" || bad "phase missing from trace: $ph"
  done
  echo "  --- phase-status.md ---"; sed 's/^/    /' "$SCR/phase-status.md"
fi

# Static checks were configured, so the phase must report a real result — `skip`
# means the command never reached develop or the gate.
if [ -n "${SCR:-}" ] && [ -f "$SCR/phase-status.md" ]; then
  st="$(awk -F'|' '$2 ~ /^ *static *$/ { gsub(/^ +| +$/, "", $6); r = $6 } END { print r }' "$SCR/phase-status.md")"
  [ "$st" = "pass" ] && ok "static checks ran and passed" || bad "static gate reported '${st:-missing}' (expected pass — lint was configured)"
fi

if [ "$SEED_DEFECT" -eq 1 ]; then
  if [ -s "$SCR/remediation.md" ]; then
    ok "remediation batch built: $(grep -c '^### R' "$SCR/remediation.md") item(s)"
    grep -q '^### R' "$SCR/remediation.md" && ok "batch carries at least one item" || bad "remediation.md has no R<N> items"
    if [ -s "$SCR/remediation-verify.md" ]; then
      ok "confirmation pass wrote verdicts"
      # The whole point: a real agent must answer in the parseable form.
      grep -qE '^[[:space:]]*[-*]?[[:space:]]*R[0-9]+[[:space:]]*:[[:space:]]*(resolved|unresolved)' "$SCR/remediation-verify.md" \
        && ok "verdicts are in the parseable '- R<N>: resolved|unresolved' form" \
        || { bad "verdicts unparseable — remediation-verify.sh would score every item unresolved"; sed 's/^/    /' "$SCR/remediation-verify.md"; }
      echo "  --- remediation-verify.md ---"; sed 's/^/    /' "$SCR/remediation-verify.md"
    else
      bad "no remediation-verify.md — the confirmation pass never ran"
    fi
    # One automatic round, not a loop.
    rounds="$(grep -c 'remediation-fix' "$SCR/dispatch-log.md" 2>/dev/null)" || rounds=0
    [ "${rounds:-0}" -le 1 ] && ok "at most one automatic remediation round (dispatches: $rounds)" \
      || bad "remediation ran $rounds times — the one-round guard did not hold"
  else
    bad "--seed-defect was set but no remediation.md was built (gate never went red)"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mE2E smoke: PASS\033[0m"; else echo -e "\033[31mE2E smoke: FAIL\033[0m"; fi
exit "$fail"
