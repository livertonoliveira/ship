#!/usr/bin/env bash

# What the test fan-out is handed, and whether it is dispatched at all.
#
# All four behaviors here were observed failing together on one live run: a
# layer with no contract row still got a worker and invented a test outside the
# contract; a layer whose file develop had already written got a worker that
# produced nothing; the brief carried acceptance criteria belonging to other
# slices of the requirement; and the "existing tests" block was the entire test
# tree — 908 paths, ~95% of a 70KB brief, repeated per worker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# Built by concatenation so this file carries no spec-id literals; the fixtures
# still exercise the real parsing at runtime.
SCEN_ID="@S"'C-01'
AC_IN="A"'C-01'
AC_OUT="A"'C-99'

next() { local dir="$1"; shift; (cd "$dir" && bash "$PIPELINE" next "$@"); }
field() { printf '%s\n' "$1" | grep -m1 "^$2=" | cut -d= -f2-; }
scratch_of() { printf '%s/.context/ship-run/%s' "$1" "$2"; }

setup_repo() {
  local dir="$1" test_scope="$2"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main .
    git config user.email t@t
    git config user.name T
    mkdir ship
    printf '# Config\n\n- Artifact language: en\n\n## Linear Integration\n- Configured: no\n\n## Pipeline Profile\n- profile: standard\n\n## Test Scope\n%s\n\n## Gate Behavior\n- on_fail: ask\n- on_warn: ask\n\n- Test Framework: none\n' "$test_scope" > ship/config.md
    printf '.context/\n' > .gitignore
    echo hello > a.txt
    git add -A
    git commit -qm init
    git update-ref refs/remotes/origin/main HEAD
  ) >/dev/null
}

# A spec whose in-scope criteria sit under `## Acceptance Criteria` and whose
# out-of-scope ones sit under a later quoted-requirement section — the exact
# shape that leaked another slice's criteria into the brief.
spec_with_out_of_scope_acs() {
  cat <<EOF
## Files
- create \`src/b.js\` — the module

## Acceptance Criteria
- $AC_IN: the module greets by name.

## Scenarios
$SCEN_ID @unit
Scenario: greets
  Given a name
  Then it greets

## Full requirement text
- $AC_OUT: importing a bank statement deduplicates by transaction id.
EOF
}

plan_with_contract() {
  local layer="$1" path="$2"
  cat <<EOF
## Modules
### M1: core
- Files: src/b.js
- Depends on: none
- Contract: does things
- Scenarios: $SCEN_ID

## Test Contract

### $SCEN_ID -> $layer -> $path
- arrange: x
- act: y
- assert: z

## Order
- M1
EOF
}

# Drives the pipeline to the point just before the verification fan-out.
drive_to_verify() {
  local dir="$1" task="$2" layer="${3:-unit}" testpath="${4:-src/b.test.js}"
  local scratch; scratch="$(scratch_of "$dir" "$task")"
  next "$dir" "$task" >/dev/null
  spec_with_out_of_scope_acs > "$scratch/spec.md"
  local i out state
  for i in 1 2 3 4 5 6; do
    out="$(next "$dir" "$task" 2>/dev/null)" || return 1
    state="$(field "$out" state)"
    case "$state" in
      plan)        plan_with_contract "$layer" "$testpath" > "$scratch/plan.md" ;;
      plan-review) printf 'verdict: ok\n' > "$scratch/plan-review.md" ;;
      develop)     mkdir -p "$dir/src"; echo 'module.exports=1' > "$dir/src/b.js" ;;
      verify-a)    printf '%s' "$out"; return 0 ;;
    esac
  done
  printf '%s' "$out"
}

test_layer_without_contract_is_not_dispatched() {
  local name="a layer with no Test Contract row gets no worker, and the skip is reported"
  local dir out scratch
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: enabled
- e2e: disabled'
  # The contract routes the only scenario to unit; integration has zero rows.
  out="$(drive_to_verify "$dir" TASK-1 unit src/b.test.js)"
  scratch="$(scratch_of "$dir" TASK-1)"
  if printf '%s' "$out" | grep -q 'ship-test-unit' \
    && ! printf '%s' "$out" | grep -q 'ship-test-integration' \
    && grep -q 'integration(no-contract)' "$scratch/verify-a.txt" \
    && printf '%s' "$out" | grep -q 'skipped: integration(no-contract)'; then
    log_pass "$name"
  else
    log_fail "$name (out state=$(field "$out" state), verify-a='$(cat "$scratch/verify-a.txt" 2>/dev/null | tr '\n' ' ')')"
  fi
  rm -rf "$dir"
}

test_layer_already_authored_by_develop_is_not_dispatched() {
  local name="a layer whose every contract file develop already wrote gets no worker"
  local dir out scratch
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled'
  local sc; sc="$(scratch_of "$dir" TASK-1)"
  next "$dir" TASK-1 >/dev/null
  spec_with_out_of_scope_acs > "$sc/spec.md"
  local i state
  for i in 1 2 3 4 5 6; do
    out="$(next "$dir" TASK-1 2>/dev/null)" || break
    state="$(field "$out" state)"
    case "$state" in
      plan)        plan_with_contract unit src/b.test.js > "$sc/plan.md" ;;
      plan-review) printf 'verdict: ok\n' > "$sc/plan-review.md" ;;
      develop)
        mkdir -p "$dir/src"
        echo 'module.exports=1' > "$dir/src/b.js"
        # develop implements the contract's test itself, as the plan's module
        # list told it to.
        echo 'it(1)' > "$dir/src/b.test.js"
        ;;
      verify-a) break ;;
    esac
  done
  scratch="$sc"
  if ! printf '%s' "$out" | grep -q 'ship-test-unit' \
    && grep -q 'unit(authored-by-develop)' "$scratch/verify-a.txt"; then
    log_pass "$name"
  else
    log_fail "$name (verify-a='$(cat "$scratch/verify-a.txt" 2>/dev/null | tr '\n' ' ')')"
  fi
  rm -rf "$dir"
}

test_brief_acs_are_scoped_to_their_section() {
  local name="the brief carries only the spec's own acceptance criteria, not another slice's"
  local dir brief
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled'
  drive_to_verify "$dir" TASK-1 unit src/b.test.js >/dev/null
  brief="$(scratch_of "$dir" TASK-1)/test-brief-unit.md"
  if [ -f "$brief" ] && grep -q "$AC_IN" "$brief" && ! grep -q "$AC_OUT" "$brief"; then
    log_pass "$name"
  else
    log_fail "$name (brief=$brief)"
  fi
  rm -rf "$dir"
}

test_existing_tests_block_is_filtered() {
  local name="the existing-tests block lists only same-layer neighbours, not the whole tree"
  local dir brief
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled'
  mkdir -p "$dir/test/unit" "$dir/test/e2e" "$dir/test/integration"
  echo 'it(1)' > "$dir/test/unit/b.spec.js"
  echo 'it(1)' > "$dir/test/e2e/checkout.e2e-spec.js"
  echo 'it(1)' > "$dir/test/integration/billing.spec.js"
  (cd "$dir" && git add -A && git commit -qm tests && git update-ref refs/remotes/origin/main HEAD) >/dev/null
  drive_to_verify "$dir" TASK-1 unit test/unit/b.spec.js >/dev/null
  brief="$(scratch_of "$dir" TASK-1)/test-brief-unit.md"
  if [ -f "$brief" ] \
    && grep -q 'test/unit/b.spec.js' "$brief" \
    && ! grep -q 'checkout.e2e-spec.js' "$brief" \
    && ! grep -q 'billing.spec.js' "$brief"; then
    log_pass "$name"
  else
    log_fail "$name (brief=$brief)"
  fi
  rm -rf "$dir"
}

test_style_ref_is_layer_appropriate() {
  local name="the style reference is a same-layer neighbour, not the first file git happens to list"
  local dir brief ref
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled'
  mkdir -p "$dir/test/unit/services" "$dir/test/e2e"
  # Alphabetically first, and the winner under the old leading-prefix scoring —
  # sources under src/ and tests under test/ share no leading segment, so every
  # candidate scored 0 and git ls-files order decided.
  echo 'it(1)' > "$dir/test/e2e/aaa-unrelated.e2e-spec.js"
  echo 'it(1)' > "$dir/test/unit/services/b.spec.js"
  (cd "$dir" && git add -A && git commit -qm tests && git update-ref refs/remotes/origin/main HEAD) >/dev/null
  drive_to_verify "$dir" TASK-1 unit test/unit/services/b2.spec.js >/dev/null
  brief="$(scratch_of "$dir" TASK-1)/test-brief-unit.md"
  ref="$(grep -m1 'Style reference' "$brief" 2>/dev/null || true)"
  if printf '%s' "$ref" | grep -q 'test/unit/services/b.spec.js' \
    && ! printf '%s' "$ref" | grep -q 'aaa-unrelated'; then
    log_pass "$name"
  else
    log_fail "$name (ref='$ref')"
  fi
  rm -rf "$dir"
}

test_no_style_ref_beats_a_wrong_one() {
  local name="with no related test anywhere, no style reference is cited at all"
  local dir brief
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: enabled
- integration: disabled
- e2e: disabled'
  mkdir -p "$dir/other"
  echo 'it(1)' > "$dir/other/zzz.spec.js"
  (cd "$dir" && git add -A && git commit -qm tests && git update-ref refs/remotes/origin/main HEAD) >/dev/null
  drive_to_verify "$dir" TASK-1 unit src/b.test.js >/dev/null
  brief="$(scratch_of "$dir" TASK-1)/test-brief-unit.md"
  if [ -f "$brief" ] && ! grep -q 'zzz.spec.js' "$brief"; then
    log_pass "$name"
  else
    log_fail "$name (brief cited an unrelated file as the pattern)"
  fi
  rm -rf "$dir"
}

test_develop_authored_tests_reach_the_manifest() {
  local name="a test file develop wrote reaches generated-tests.md, so the suite actually runs it"
  local dir out sc state i
  dir="$(mktemp -d)"
  setup_repo "$dir" '- unit: disabled
- integration: disabled
- e2e: enabled'
  sc="$(scratch_of "$dir" TASK-1)"
  next "$dir" TASK-1 >/dev/null
  spec_with_out_of_scope_acs > "$sc/spec.md"
  for i in 1 2 3 4 5 6 7 8; do
    out="$(next "$dir" TASK-1 2>/dev/null)" || break
    state="$(field "$out" state)"
    case "$state" in
      plan)        plan_with_contract e2e test/e2e/b.e2e-spec.js > "$sc/plan.md" ;;
      plan-review) printf 'verdict: ok\n' > "$sc/plan-review.md" ;;
      develop)
        mkdir -p "$dir/src" "$dir/test/e2e"
        echo 'module.exports=1' > "$dir/src/b.js"
        # The plan gave this file to a develop module, so no worker manifest
        # will ever name it — and that manifest is the only thing test-exec runs.
        echo 'it(1)' > "$dir/test/e2e/b.e2e-spec.js"
        ;;
      verify-a|verify-pending)
        # Satisfy the quality worker so the run reaches manifest consolidation.
        printf '| review | #<RUN> | t | - | pass | 0 | 0 | 0 | 0 | |\n' > "$sc/phase-status-review.md"
        ;;
    esac
    [ -f "$sc/generated-tests.md" ] && break
  done
  if [ -f "$sc/generated-tests.md" ] \
    && grep -q '^- test/e2e/b.e2e-spec.js (e2e)$' "$sc/generated-tests.md"; then
    log_pass "$name"
  else
    log_fail "$name (manifest='$(cat "$sc/generated-tests.md" 2>/dev/null | tr '\n' ' ')')"
  fi
  rm -rf "$dir"
}

test_layer_without_contract_is_not_dispatched
test_layer_already_authored_by_develop_is_not_dispatched
test_develop_authored_tests_reach_the_manifest
test_brief_acs_are_scoped_to_their_section
test_existing_tests_block_is_filtered
test_style_ref_is_layer_appropriate
test_no_style_ref_beats_a_wrong_one

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
