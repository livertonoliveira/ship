#!/usr/bin/env bash

# Covers the single-module shortcut's matching, which had been dead on every real
# spec: it grepped for a literal `Dependencies: None` that ship:spec never writes
# and that no non-English artifact language could produce, and it counted only
# `## Files` entries carrying a leading "- ", which Linear-mode specs omit.
#
# The shortcut is repaired but report-only — pipeline.sh records the verdict and
# still runs the planner — so these tests pin the prediction, not a skip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# Exercise the predictor exactly as pipeline.sh defines it.
PREDICT="$(mktemp)"
{
  sed -n '/^plan_deps_none() {/,/^}/p' "$PIPELINE"
  sed -n '/^plan_predict_single_module() {/,/^}/p' "$PIPELINE"
  echo 'plan_predict_single_module "$1"'
} > "$PREDICT"
trap 'rm -f "$PREDICT"' EXIT

predicts_single_module() { bash "$PREDICT" "$1"; }

assert_prediction() {
  local name="$1" spec="$2" expected="$3" got
  if predicts_single_module "$spec"; then got=single; else got=multi; fi
  if [ "$got" = "$expected" ]; then
    log_pass "$name"
  else
    log_fail "$name (predicted $got, expected $expected)"
  fi
}

# --- spec shapes seen in the wild ---------------------------------------------

test_local_mode_dashed_files_with_deps_none() {
  local d; d="$(mktemp -d)"
  cat > "$d/spec.md" <<'EOF'
## Files
- create `src/calculator.js` — the module
- create `src/calculator.test.js` — the suite

## Deps
none

## Scenarios
@unit
Scenario: works
EOF
  assert_prediction "local-mode spec with dashed files and '## Deps: none' predicts single module" \
    "$d/spec.md" single
  rm -rf "$d"
}

test_linear_mode_dashless_files_are_counted() {
  local d; d="$(mktemp -d)"
  cat > "$d/spec.md" <<'EOF'
## Files

create `src/a.use-case.ts` — one
modify `src/b.repository.ts` — two

## Deps
none

## Scenarios
@integration
Scenario: works
EOF
  assert_prediction "Linear-mode spec whose file entries carry no dash still counts them" \
    "$d/spec.md" single
  rm -rf "$d"
}

test_real_deps_block_the_shortcut() {
  local d; d="$(mktemp -d)"
  cat > "$d/spec.md" <<'EOF'
## Files
create `src/a.ts` — one

## Deps
MOB-2530
MOB-2528

## Scenarios
@unit
Scenario: works
EOF
  assert_prediction "a task listing blocking dependencies is not a single-module shortcut" \
    "$d/spec.md" multi
  rm -rf "$d"
}

test_deps_stated_only_in_prose_are_not_treated_as_none() {
  local d; d="$(mktemp -d)"
  # The api-agendx MOB-2536 shape: no `## Deps` section at all, dependencies
  # named in localized prose. Absence must default to "has deps" — guessing the
  # other way would skip planning for a task that genuinely needs it.
  cat > "$d/spec.md" <<'EOF'
## Files

create `src/application/use-cases/x.use-case.ts` — one
modify `src/infrastructure/y.repository.ts` — two

## Notes
Depende de: MOB-2530 (agregações) e MOB-2528 (marcação).

## Scenarios
@integration
Scenario: works
EOF
  assert_prediction "a spec with no ## Deps section is treated as having dependencies" \
    "$d/spec.md" multi
  rm -rf "$d"
}

test_too_many_files_blocks_the_shortcut() {
  local d; d="$(mktemp -d)"
  cat > "$d/spec.md" <<'EOF'
## Files
create `src/a.ts` — one
create `src/b.ts` — two
create `src/c.ts` — three
create `src/d.ts` — four

## Deps
none

## Scenarios
@unit
Scenario: works
EOF
  assert_prediction "more than three code entries is not a single-module task" "$d/spec.md" multi
  rm -rf "$d"
}

test_multiple_test_layers_block_the_shortcut() {
  local d; d="$(mktemp -d)"
  cat > "$d/spec.md" <<'EOF'
## Files
create `src/a.ts` — one

## Deps
none

## Scenarios
@unit
Scenario: one
@integration
Scenario: two
EOF
  assert_prediction "two test layers is not a single-module task" "$d/spec.md" multi
  rm -rf "$d"
}

test_plugins_rebuild_entries_do_not_count() {
  local d; d="$(mktemp -d)"
  cat > "$d/spec.md" <<'EOF'
## Files
create `src/a.ts` — one
modify `plugins/ship/skills/run/SKILL.md` — rebuild artifact

## Deps
none

## Scenarios
@unit
Scenario: works
EOF
  assert_prediction "generated plugins/ entries are excluded from the file count" "$d/spec.md" single
  rm -rf "$d"
}

# --- report-only wiring --------------------------------------------------------

test_prediction_is_recorded_but_not_acted_on() {
  local name="the prediction is written to the scratch dir while the planner still runs"
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/ship"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n## Test Scope\n- unit: disabled\n- integration: disabled\n- e2e: disabled\n\n## Gate Behavior\n- on_fail: ask\n- on_warn: ask\n\n- Test Framework: none\n' > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A && git commit -qm init && git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null

  local scratch="$dir/.context/ship-run/TP"
  (cd "$dir" && bash "$PIPELINE" next TP) >/dev/null 2>&1 || true
  cat > "$scratch/spec.md" <<'EOF'
## Files
create `src/a.js` — one

## Deps
none

## Scenarios
@unit
Scenario: works
EOF
  mkdir -p "$dir/src"; seq 1 120 | sed 's/^/export const v/;s/$/ = 1/' > "$dir/src/a.js"
  local out; out="$(cd "$dir" && bash "$PIPELINE" next TP 2>&1)"

  if [ "$(head -1 "$scratch/plan-prediction.txt" 2>/dev/null)" = "single-module" ] \
    && [ "$(head -1 "$scratch/plan-decision.txt" 2>/dev/null)" = "run" ] \
    && printf '%s' "$out" | grep -q 'Skill ship:plan'; then
    log_pass "$name"
  else
    log_fail "$name (prediction=$(head -1 "$scratch/plan-prediction.txt" 2>/dev/null) decision=$(head -1 "$scratch/plan-decision.txt" 2>/dev/null))"
  fi
  rm -rf "$dir"
}

test_local_mode_dashed_files_with_deps_none
test_linear_mode_dashless_files_are_counted
test_real_deps_block_the_shortcut
test_deps_stated_only_in_prose_are_not_treated_as_none
test_too_many_files_blocks_the_shortcut
test_multiple_test_layers_block_the_shortcut
test_plugins_rebuild_entries_do_not_count
test_prediction_is_recorded_but_not_acted_on

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
