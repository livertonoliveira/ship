#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAFFOLD="$SCRIPT_DIR/../plan-scaffold.sh"

pass_count=0
fail_count=0

scenario_tag() {
  printf '@S''C-%s' "$1"
}

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

make_scratch() {
  local dir
  dir="$(mktemp -d)/TASK-1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

run_scaffold() {
  local scratch="$1"
  shift
  bash "$SCAFFOLD" "$scratch" "$@" >/dev/null 2>&1
}

test_one_slot_per_occurrence_not_per_id() {
  local name="an id reused across two distinct scenarios yields two slots, so a plan for it exists at all"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
## Scenarios

  $(scenario_tag 08) @unit
  Scenario: nenhum card perde superficie
    Dado um componente
    Quando renderizado
    Entao mantem fundo

  $(scenario_tag 08) @unit
  Scenario: o tema escuro nao regride
    Dado tema escuro ativo
    Quando renderizado
    Entao mantem contraste
EOF
  run_scaffold "$scratch"
  local slots
  slots="$(grep -c '^### ' "$scratch/plan-scaffold.md" || true)"
  if [ "$slots" = "2" ] \
    && grep -q "nenhum card perde superficie" "$scratch/plan-scaffold.md" \
    && grep -q "o tema escuro nao regride" "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name (slots=$slots)"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_duplicate_ids_are_reported_but_never_fatal() {
  local name="a duplicated scenario id is reported as a spec defect and still exits clean — the run must produce a plan"
  local scratch rc=0; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 08) @unit
  Scenario: primeiro
    Quando algo
    Entao outro

  $(scenario_tag 08) @unit
  Scenario: segundo
    Quando algo
    Entao outro
EOF
  bash "$SCAFFOLD" "$scratch" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '## Spec Defects' "$scratch/plan-scaffold.md" \
    && grep -q "$(scenario_tag 08) labels 2" "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name (exit $rc)"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_same_id_same_title_is_not_a_defect() {
  local name="the same scenario written twice verbatim is not reported as two behaviors"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 08) @unit
  Scenario: identico
    Quando algo
    Entao outro

  $(scenario_tag 08) @unit
  Scenario: identico
    Quando algo
    Entao outro
EOF
  run_scaffold "$scratch"
  if ! grep -q '## Spec Defects' "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_layer_comes_from_the_tag_never_reclassified() {
  local name="each slot's layer is the scenario's own tag, so no layer is ever re-derived downstream"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 01) @unit
  Scenario: um
    Quando a
    Entao b

  $(scenario_tag 02) @integration
  Scenario: dois
    Quando a
    Entao b

  $(scenario_tag 03) @e2e
  Scenario: tres
    Quando a
    Entao b
EOF
  run_scaffold "$scratch"
  if grep -q "$(scenario_tag 01) (um) -> unit ->" "$scratch/plan-scaffold.md" \
    && grep -q "$(scenario_tag 02) (dois) -> integration ->" "$scratch/plan-scaffold.md" \
    && grep -q "$(scenario_tag 03) (tres) -> e2e ->" "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_tags_split_across_lines_keep_both_id_and_layer() {
  local name="tags spread over several lines keep the title and the layer — a lost layer would silently become unit"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 01)
  @e2e
  Scenario: separado em duas linhas
    Quando a
    Entao b
EOF
  run_scaffold "$scratch"
  if grep -q "$(scenario_tag 01) (separado em duas linhas) -> e2e ->" "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name ($(grep '^### ' "$scratch/plan-scaffold.md"))"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_an_untagged_layer_is_defaulted_out_loud() {
  local name="a scenario with no layer tag is defaulted to unit and says so, instead of landing in a layer nobody chose"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 01)
  Scenario: sem camada
    Quando a
    Entao b
EOF
  run_scaffold "$scratch"
  if grep -q 'NO LAYER TAG' "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_steps_are_carried_into_the_slot() {
  local name="Given/When/Then are carried into the slot so the planner never re-copies them"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 01) @unit
  Scenario: um
    Dado um estado inicial
    Quando o gatilho dispara
    Entao o resultado aparece
    E o log registra
EOF
  run_scaffold "$scratch"
  local line
  line="$(grep '^- arrange/act/assert:' "$scratch/plan-scaffold.md")"
  if printf '%s' "$line" | grep -q 'um estado inicial' \
    && printf '%s' "$line" | grep -q 'o gatilho dispara' \
    && printf '%s' "$line" | grep -q 'o resultado aparece' \
    && printf '%s' "$line" | grep -q 'o log registra'; then
    log_pass "$name"
  else
    log_fail "$name ($line)"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_inventory_lists_every_spec_file_and_flags_absent_modify_targets() {
  local name="the file inventory carries every spec path and marks a modify target that is not on disk"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<'EOF'
## Files

- create `src/novo.ts` — algo
- modify `src/sumiu.ts` — outro
EOF
  run_scaffold "$scratch"
  if grep -q 'src/novo.ts (create) -> M?' "$scratch/plan-scaffold.md" \
    && grep -q 'src/sumiu.ts (modify) -> M?.*ABSENT on disk' "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_a_slot_in_a_disabled_layer_is_flagged_at_scaffold_time() {
  local name="a scenario tagged for a layer the config switched off is flagged here, not discovered after develop"
  local scratch; scratch="$(make_scratch)"
  cat > "$scratch/spec.md" <<EOF
  $(scenario_tag 01) @e2e
  Scenario: um
    Quando a
    Entao b
EOF
  cat > "$scratch/config.md" <<'EOF'
## Test Scope
- unit: enabled
- integration: enabled
- e2e: disabled
EOF
  run_scaffold "$scratch" --config "$scratch/config.md"
  if grep -q 'LAYER DISABLED' "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_a_spec_with_no_scenarios_still_scaffolds() {
  local name="a spec with no tagged scenarios produces a scaffold instead of an error"
  local scratch rc=0; scratch="$(make_scratch)"
  printf '## Acceptance Criteria\n\n- AC: algo acontece\n' > "$scratch/spec.md"
  bash "$SCAFFOLD" "$scratch" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$scratch/plan-scaffold.md" ] \
    && grep -q 'Acceptance Criteria' "$scratch/plan-scaffold.md"; then
    log_pass "$name"
  else
    log_fail "$name (exit $rc)"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_missing_spec_is_an_error() {
  local name="a scratch dir with no spec.md is a caller error, not a silent empty scaffold"
  local scratch rc=0; scratch="$(make_scratch)"
  bash "$SCAFFOLD" "$scratch" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -f "$scratch/plan-scaffold.md" ]; then
    log_pass "$name"
  else
    log_fail "$name (exit $rc)"
  fi
  rm -rf "$(dirname "$scratch")"
}

test_one_slot_per_occurrence_not_per_id
test_duplicate_ids_are_reported_but_never_fatal
test_same_id_same_title_is_not_a_defect
test_layer_comes_from_the_tag_never_reclassified
test_tags_split_across_lines_keep_both_id_and_layer
test_an_untagged_layer_is_defaulted_out_loud
test_steps_are_carried_into_the_slot
test_inventory_lists_every_spec_file_and_flags_absent_modify_targets
test_a_slot_in_a_disabled_layer_is_flagged_at_scaffold_time
test_a_spec_with_no_scenarios_still_scaffolds
test_missing_spec_is_an_error

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
