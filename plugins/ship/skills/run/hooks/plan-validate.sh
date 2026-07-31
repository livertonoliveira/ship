#!/usr/bin/env bash

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: plan-validate.sh <plan-file> [--scaffold <file>] [--spec <spec-file>] [--config <path>]" >&2
  echo "  With a scaffold (auto-detected beside the plan) the plan is confronted" >&2
  echo "  with it instead of with the spec: the derived lists were generated, not" >&2
  echo "  transcribed, so only the planner's own assignments are checked." >&2
  echo "  Without --spec only the plan's internal consistency is checked." >&2
  echo "  With --spec the plan is also confronted with the spec and the" >&2
  echo "  repository: no spec scenario or spec file may be silently dropped," >&2
  echo "  and a path the spec marks 'modify' must exist on disk." >&2
}

module_ids() {
  local f="$1"
  grep -oE '^### M[0-9]+:' "$f" 2>/dev/null | sed -E 's/^### (M[0-9]+):/\1/'
}

module_section() {
  local f="$1" id="$2"
  awk -v id="$id" '
    $0 ~ "^### " id ":" { capture=1; next }
    capture && /^### M[0-9]+:/ { capture=0 }
    capture && /^## / { capture=0 }
    capture { print }
  ' "$f"
}

module_field() {
  local f="$1" id="$2" field="$3"
  module_section "$f" "$id" | grep -E "^- ${field}:" | head -1 | sed -E "s/^- ${field}:[[:space:]]*//"
}

module_files() {
  local f="$1" id="$2" raw
  raw="$(module_field "$f" "$id" "Files")"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$' || true
}

module_scenarios() {
  local f="$1" id="$2" raw
  raw="$(module_field "$f" "$id" "Scenarios")"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -E '^@SC-[0-9]+' || true
}

module_depends_on() {
  local f="$1" id="$2" raw
  raw="$(module_field "$f" "$id" "Depends on")"
  [ -n "$raw" ] || return 0
  if [ "$raw" = "none" ]; then
    return 0
  fi
  printf '%s\n' "$raw" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$' || true
}

# A slot header may carry a qualifier between the scenario id and the first
# arrow: `### <id> (dark theme) -> unit -> <file>`. Requiring the bare id made a
# spec that reuses one scenario id across two behaviorally distinct scenarios
# impossible to plan at all — one id can hold one slot, so the planner had no
# valid output and every replan failed the same way. The leading non-digit guard
# keeps an id from matching a longer one with the same prefix.
slot_header_re() {
  printf '^### %s([^0-9][^>]*)?->' "$1"
}

test_contract_layer_for() {
  local f="$1" scenario_id="$2"
  grep -E "$(slot_header_re "$scenario_id")" "$f" 2>/dev/null \
    | head -1 \
    | sed -E 's/^### [^>]+->[[:space:]]*([a-zA-Z0-9]+)[[:space:]]*->.*/\1/'
}

test_contract_slot_exists() {
  local f="$1" scenario_id="$2"
  grep -qE "$(slot_header_re "$scenario_id")" "$f" 2>/dev/null
}

check_module_map_present() {
  local f="$1" ids
  ids="$(module_ids "$f")"
  [ -n "$ids" ]
}

check_overlap() {
  local f="$1" id path ids entries=()
  ids="$(module_ids "$f")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      entries+=("${path}|${id}")
    done < <(module_files "$f" "$id")
  done <<< "$ids"

  [ "${#entries[@]}" -gt 0 ] || return 0

  local sorted prev_path prev_id cur_path cur_id line
  sorted="$(printf '%s\n' "${entries[@]}" | sort)"
  prev_path=""
  prev_id=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cur_path="${line%%|*}"
    cur_id="${line#*|}"
    if [ "$cur_path" = "$prev_path" ] && [ "$cur_id" != "$prev_id" ]; then
      echo "plan-validate: overlap de arquivos — $cur_path em $prev_id, $cur_id" >&2
      return 1
    fi
    prev_path="$cur_path"
    prev_id="$cur_id"
  done <<< "$sorted"
  return 0
}

check_scenario_layers() {
  local f="$1" ids id scenario layer
  ids="$(module_ids "$f")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    while IFS= read -r scenario; do
      [ -n "$scenario" ] || continue
      if ! test_contract_slot_exists "$f" "$scenario"; then
        echo "plan-validate: cenário órfão — $scenario sem slot no Test Contract" >&2
        return 1
      fi
      layer="$(test_contract_layer_for "$f" "$scenario")"
      case "$layer" in
        unit|integration|e2e) ;;
        *)
          echo "plan-validate: camada inválida — $scenario -> $layer" >&2
          return 1
          ;;
      esac
    done < <(module_scenarios "$f" "$id")
  done <<< "$ids"
  return 0
}

# Every Test Contract slot as "<layer> <path>".
contract_slots() {
  grep -E '^### .* -> .* -> ' "$1" 2>/dev/null \
    | sed -E 's/^### .* -> ([^>]*) -> (.*)$/\1 \2/' \
    | sed -E 's/[[:space:]]*\(derived[^)]*\)[[:space:]]*$//' \
    | sed 's/`//g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true
}

# A slot is only worth anything if its file will actually be run.
#
# Two ways a slot silently produces no coverage, both observed together on the
# same run: the layer is disabled in `## Test Scope`, so no worker is ever
# scoped to it; or the path's own naming puts it in a different layer than the
# slot declares, so it lands under a runner config that cannot see it. Either
# way the scenario ends up with a test file on disk that nothing executes, and
# the gate reports green.
check_contract_slots_runnable() {
  local f="$1" config="$2" line layer path actual disabled=""
  [ -f "$HOOK_DIR/test-layer.sh" ] || return 0

  # A slot in a disabled layer is only dead coverage if the test phase actually
  # runs. With `## Pipeline Phases → test: disabled` nothing is generated for any
  # layer by design, so no slot means anything and there is nothing to report.
  if [ -n "$config" ] && [ -f "$config" ] && [ -f "$HOOK_DIR/test-scope.sh" ] \
    && ! grep -qE '^-[[:space:]]*test:[[:space:]]*disabled' "$config"; then
    disabled=" $(bash "$HOOK_DIR/test-scope.sh" --config "$config" | grep '^skip=' | sed 's/^skip=//') "
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    layer="${line%% *}"
    path="${line#* }"
    [ -n "$path" ] && [ "$path" != "$layer" ] || continue

    if [ -n "$disabled" ] && [ "$disabled" != "  " ]; then
      case "$disabled" in
        *" $layer "*)
          echo "plan-validate: slot em camada desabilitada no ## Test Scope — $layer -> $path (nenhum worker é escopado para ela; mova o cenário para uma camada habilitada ou habilite-a)" >&2
          return 1
          ;;
      esac
    fi

    actual="$(bash "$HOOK_DIR/test-layer.sh" classify "$path" | cut -f1)"
    if [ "$actual" != "unknown" ] && [ "$actual" != "$layer" ]; then
      echo "plan-validate: caminho contradiz a camada do slot — declarado '$layer', o path '$path' é '$actual' (ele rodaria sob outro runner, ou sob nenhum)" >&2
      return 1
    fi
  done < <(contract_slots "$f")
  return 0
}

check_dependency_refs() {
  local f="$1" ids id dep known_ids
  ids="$(module_ids "$f")"
  known_ids=" $(printf '%s ' $ids)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$known_ids" in
        *" $dep "*) ;;
        *)
          echo "plan-validate: dependência inválida — $id referencia $dep inexistente" >&2
          return 1
          ;;
      esac
    done < <(module_depends_on "$f" "$id")
  done <<< "$ids"
  return 0
}

node_color() {
  local node="$1" colors="$2"
  case "$colors" in
    *" ${node}=gray "*) printf 'gray' ;;
    *" ${node}=black "*) printf 'black' ;;
    *) printf 'white' ;;
  esac
}

set_node_color() {
  local node="$1" color="$2" colors="$3" stripped
  stripped="${colors// ${node}=gray /}"
  stripped="${stripped// ${node}=black /}"
  stripped="${stripped// ${node}=white /}"
  printf ' %s%s=%s ' "$stripped" "$node" "$color"
}

neighbors_of() {
  local f="$1" node="$2"
  module_depends_on "$f" "$node"
}

format_cycle_path() {
  local next_node="$1"
  shift
  local path=("$@")
  local cycle_start_idx=-1
  local k
  for ((k = 0; k < ${#path[@]}; k++)); do
    if [ "${path[$k]}" = "$next_node" ]; then
      cycle_start_idx=$k
      break
    fi
  done
  local cycle_path=("${path[@]:$cycle_start_idx}")
  cycle_path+=("$next_node")
  local joined=""
  local part
  for part in "${cycle_path[@]}"; do
    if [ -z "$joined" ]; then
      joined="$part"
    else
      joined="$joined -> $part"
    fi
  done
  printf '%s' "$joined"
}

check_cycle() {
  local f="$1" ids id all_nodes=""

  ids="$(module_ids "$f")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    all_nodes="$all_nodes $id"
  done <<< "$ids"

  local colors=" "
  local node
  for node in $all_nodes; do
    colors="$(set_node_color "$node" white "$colors")"
  done

  for node in $all_nodes; do
    [ "$(node_color "$node" "$colors")" = "white" ] || continue

    local path=("$node")
    local iter_stack=("$node:0")
    colors="$(set_node_color "$node" gray "$colors")"

    while [ "${#iter_stack[@]}" -gt 0 ]; do
      local top_idx=$((${#iter_stack[@]} - 1))
      local top="${iter_stack[$top_idx]}"
      local cur="${top%%:*}"
      local neighbor_idx="${top##*:}"
      local neighbors=($(neighbors_of "$f" "$cur"))

      if [ "$neighbor_idx" -lt "${#neighbors[@]}" ]; then
        local next_node="${neighbors[$neighbor_idx]}"
        iter_stack[$top_idx]="${cur}:$((neighbor_idx + 1))"

        local next_color
        next_color="$(node_color "$next_node" "$colors")"

        case "$next_color" in
          white)
            colors="$(set_node_color "$next_node" gray "$colors")"
            iter_stack+=("${next_node}:0")
            path+=("$next_node")
            ;;
          gray)
            local joined
            joined="$(format_cycle_path "$next_node" "${path[@]}")"
            echo "plan-validate: ciclo de dependência — $joined" >&2
            return 1
            ;;
          black) ;;
        esac
      else
        colors="$(set_node_color "$cur" black "$colors")"
        unset "iter_stack[$top_idx]"
        iter_stack=("${iter_stack[@]+"${iter_stack[@]}"}")
        local path_last_idx=$((${#path[@]} - 1))
        unset "path[$path_last_idx]"
        path=("${path[@]+"${path[@]}"}")
      fi
    done
  done
  return 0
}

# --- confrontation with the spec and the repository --------------------------
# The checks above prove the plan is coherent with itself; a plan can pass all
# of them while quietly dropping a scenario the spec asked for or pointing at a
# file that does not exist. Those defects do not surface until develop and test
# have both consumed the plan, which makes them gate findings — the most
# expensive place to discover them. These three close that gap deterministically.

spec_scenarios() {
  grep -oE '@SC-[0-9]+' "$1" 2>/dev/null | sort -u || true
}

plan_scenarios() {
  local f="$1" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    module_scenarios "$f" "$id"
  done < <(module_ids "$f") | grep -oE '@SC-[0-9]+' | sort -u || true
}

# `## Files` entries: "create|modify `<path>` — <intent>", with or without a
# leading "- ". Both shapes occur in practice — the local-mode fixture writes the
# dash, a real Linear-mode spec does not — and requiring it made this check
# extract nothing and pass vacuously on half the specs it exists for.
# `Âncora:` lines are pattern references, not owned files, so they never reach
# the plan.
spec_files() {
  local spec="$1" kind="${2:-}"
  awk -v kind="$kind" '
    /^## Files/ { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^[[:space:]]*(-[[:space:]]*)?(create|modify|Âncora|Ancora|Anchor)/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/`/, "", line)
      if (line ~ /^(Âncora|Ancora|Anchor)[[:space:]]*:/) next
      if (!match(line, /^(create|modify)[[:space:]]+/)) next
      verb = substr(line, 1, RLENGTH - 1)
      sub(/[[:space:]]+$/, "", verb)
      sub(/^(create|modify)[[:space:]]+/, "", line)
      sub(/[[:space:]]*(—|–|--).*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") next
      if (kind != "" && verb != kind) next
      print line
    }
  ' "$spec" 2>/dev/null | sort -u || true
}

plan_files() {
  local f="$1" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    module_files "$f" "$id"
  done < <(module_ids "$f") | sed 's/`//g' | sort -u || true
}

# A spec path the planner deliberately corrected (moved, gone, replaced) is
# logged under `## Map Divergences` — accounted for even though no module lists
# it. This is what keeps the divergence log load-bearing instead of decorative.
#
# Only `- ` entries count, per the format ship:plan writes. Scanning the whole
# section for path-shaped tokens made the check self-defeating: a planner that
# wrote "none — src/a.test.js validated against the tree" had every file it
# merely MENTIONED counted as diverged, so a plan that genuinely dropped a file
# passed as long as its prose named it.
diverged_paths() {
  awk '
    /^## Map Divergences/ { insection = 1; next }
    /^## / { insection = 0 }
    insection && /^[[:space:]]*-[[:space:]]/ { print }
  ' "$1" 2>/dev/null | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | sort -u || true
}

# --- confrontation with the scaffold ----------------------------------------
# When plan-scaffold.sh generated the derived lists, the plan is checked against
# THEM rather than against the spec. The difference matters: the spec has to be
# interpreted, and both the planner and this validator interpreting it
# separately is exactly how a plan came to fail on a spec it had transcribed
# faithfully. The scaffold is one interpretation, produced once, and all that is
# left to check is that the planner assigned every row it was handed.

# "S<n>|<layer>" for every slot the scaffold keyed. The key is what identifies a
# slot: an id cannot (two scenarios may share one) and a title should not (it
# would make the plan hinge on re-typing accented prose byte for byte).
slot_keys() {
  grep -E '^### S[0-9]+[^>]*->' "$1" 2>/dev/null \
    | sed -E 's/^### (S[0-9]+)[^>]*->[[:space:]]*([a-zA-Z0-9]+)[[:space:]]*->.*/\1|\2/' \
    | sort || true
}

# Slots carrying no key — everything the planner added on its own.
unkeyed_slots() {
  grep -E '^### .*->.*->' "$1" 2>/dev/null \
    | grep -vE '^### S[0-9]+[^>]*->' || true
}

scaffold_inventory() {
  grep -E '^- .* \((create|modify)\)' "$1" 2>/dev/null \
    | sed -E 's/^- (.*) \((create|modify)\).*/\1/' \
    | sed 's/`//g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sort -u || true
}

check_contract_matches_scaffold() {
  local f="$1" scaffold="$2" missing extra
  # A spec with no tagged scenarios scaffolds no slots and tells the planner to
  # derive them from the acceptance criteria instead. There the scaffold is not
  # the authority on the contract, so neither direction of this comparison means
  # anything — checking it would reject every slot the planner correctly derived.
  [ -n "$(slot_keys "$scaffold")" ] || return 0
  missing="$(comm -23 <(slot_keys "$scaffold") <(slot_keys "$f"))"
  if [ -n "$missing" ]; then
    echo "plan-validate: slot do scaffold ausente ou re-camadado no plano — $(printf '%s' "$missing" | tr '\n' ' ')" >&2
    return 1
  fi
  extra="$(comm -13 <(slot_keys "$scaffold") <(slot_keys "$f"))"
  if [ -n "$extra" ]; then
    echo "plan-validate: slot com chave que o scaffold não emitiu — $(printf '%s' "$extra" | tr '\n' ' ')" >&2
    return 1
  fi
  # An unkeyed slot is one the planner added. That is legitimate for an AC
  # outcome no scenario covers — it holds both lists, so it is the only stage
  # that can see the gap — but it has to say so, or the contract grows tests
  # nothing traces back to.
  extra="$(unkeyed_slots "$f" | grep -v '(derived' || true)"
  if [ -n "$extra" ]; then
    echo "plan-validate: slot fora do scaffold e não marcado '(derived: ...)' — $(printf '%s' "$extra" | head -3 | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

check_inventory_assigned() {
  local f="$1" scaffold="$2" missing
  missing="$(comm -23 <(scaffold_inventory "$scaffold") \
    <(cat <(plan_files "$f") <(contract_files "$f") <(diverged_paths "$f") | sort -u))"
  if [ -n "$missing" ]; then
    echo "plan-validate: arquivo do inventário sem módulo (e sem registro em ## Map Divergences) — $(printf '%s' "$missing" | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

# The one field the scaffold deliberately leaves open: the test path follows the
# repo's own conventions, which only the planner surveyed.
check_no_unfilled_slots() {
  local f="$1" left
  left="$(grep -E '^### .*->.*->[[:space:]]*TBD([[:space:]]|$)' "$f" 2>/dev/null || true)"
  if [ -n "$left" ]; then
    echo "plan-validate: slot com caminho de teste não preenchido (TBD) — $(printf '%s' "$left" | head -3 | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

check_spec_scenarios_claimed() {
  local f="$1" spec="$2" missing
  missing="$(comm -23 <(spec_scenarios "$spec") <(plan_scenarios "$f"))"
  if [ -n "$missing" ]; then
    echo "plan-validate: cenário do spec sem módulo — $(printf '%s' "$missing" | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

# Test files the spec lists are owned by the `## Test Contract`, not by a module's
# `Files:` — pipeline.sh's next_module_files even strips them back out of the
# module set. Requiring a module to claim them would fail every plan that puts
# tests where they belong, so they are accounted for by a Test Contract slot.
contract_files() {
  grep -E '^### .* -> .* -> ' "$1" 2>/dev/null \
    | sed -E 's/^### .* -> [^>]* -> //' \
    | sed -E 's/[[:space:]]*\(derived[^)]*\)[[:space:]]*$//' \
    | sed 's/`//g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sort -u || true
}

check_spec_files_claimed() {
  local f="$1" spec="$2" missing
  missing="$(comm -23 <(spec_files "$spec") \
    <(cat <(plan_files "$f") <(contract_files "$f") <(diverged_paths "$f") | sort -u))"
  if [ -n "$missing" ]; then
    echo "plan-validate: arquivo do spec sem módulo (e sem registro em ## Map Divergences) — $(printf '%s' "$missing" | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

check_modify_targets_exist() {
  local f="$1" spec="$2" path planned missing=""
  planned="$(plan_files "$f")"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' "$planned" | grep -qxF "$path" || continue
    [ -e "$path" ] && continue
    missing="$missing $path"
  done < <(spec_files "$spec" modify)
  if [ -n "$missing" ]; then
    echo "plan-validate: alvo 'modify' inexistente no repositório —$missing" >&2
    return 1
  fi
  return 0
}

validate_plan() {
  local f="$1" spec="${2:-}" config="${3:-}" scaffold="${4:-}"

  # Decisions the planner actually made — the only things left worth checking.
  if ! check_module_map_present "$f"; then
    echo "plan-validate: module map vazio" >&2
    return 2
  fi

  if ! check_overlap "$f"; then
    return 2
  fi

  if ! check_dependency_refs "$f"; then
    return 2
  fi

  if ! check_cycle "$f"; then
    return 2
  fi

  if ! check_contract_slots_runnable "$f" "$config"; then
    return 2
  fi

  # Scaffolded run: the derived lists were handed to the planner, so all that is
  # left is that it assigned them. These replace the four spec-transcription
  # checks below, which no longer have anything to catch.
  if [ -n "$scaffold" ] && [ -f "$scaffold" ]; then
    if ! check_no_unfilled_slots "$f"; then
      return 2
    fi
    if ! check_contract_matches_scaffold "$f" "$scaffold"; then
      return 2
    fi
    if ! check_inventory_assigned "$f" "$scaffold"; then
      return 2
    fi
    return 0
  fi

  # Standalone / legacy: no scaffold was generated, so the spec is still the only
  # thing to confront the plan with.
  if ! check_scenario_layers "$f"; then
    return 2
  fi

  [ -n "$spec" ] && [ -f "$spec" ] || return 0

  if ! check_spec_scenarios_claimed "$f" "$spec"; then
    return 2
  fi

  if ! check_spec_files_claimed "$f" "$spec"; then
    return 2
  fi

  if ! check_modify_targets_exist "$f" "$spec"; then
    return 2
  fi

  return 0
}

main() {
  local positional=() spec="" config="" scaffold=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --scaffold)
        scaffold="${2:-}"
        if [ -z "$scaffold" ]; then
          echo "plan-validate: --scaffold requires a path" >&2
          exit 1
        fi
        shift 2
        ;;
      --spec)
        spec="${2:-}"
        if [ -z "$spec" ]; then
          echo "plan-validate: --spec requires a path" >&2
          exit 1
        fi
        shift 2
        ;;
      --config)
        config="${2:-}"
        if [ -z "$config" ]; then
          echo "plan-validate: --config requires a path" >&2
          exit 1
        fi
        shift 2
        ;;
      --*)
        echo "plan-validate: unknown flag: $1" >&2
        usage
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ "${#positional[@]}" -ne 1 ]; then
    echo "plan-validate: expected 1 argument, got ${#positional[@]}" >&2
    usage
    exit 1
  fi
  local plan_file="${positional[0]}"

  if [ ! -f "$plan_file" ]; then
    echo "plan-validate: plan file not found: $plan_file" >&2
    exit 1
  fi

  if [ -n "$spec" ] && [ ! -f "$spec" ]; then
    echo "plan-validate: spec file not found: $spec" >&2
    exit 1
  fi

  # The scaffold lives beside the plan; the flag only has to name it when the two
  # are apart, so a caller that forgets it still gets the scaffolded checks.
  if [ -z "$scaffold" ]; then
    local sibling="$(dirname "$plan_file")/plan-scaffold.md"
    [ -f "$sibling" ] && scaffold="$sibling"
  fi

  if validate_plan "$plan_file" "$spec" "$config" "$scaffold"; then
    echo "plan-validate: plan válido"
    exit 0
  else
    exit 2
  fi
}

main "$@"
