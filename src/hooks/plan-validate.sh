#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: plan-validate.sh <plan-file>" >&2
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

test_contract_layer_for() {
  local f="$1" scenario_id="$2"
  grep -E "^### ${scenario_id}[[:space:]]*->" "$f" 2>/dev/null \
    | head -1 \
    | sed -E 's/^### [^>]+->[[:space:]]*([a-zA-Z0-9]+)[[:space:]]*->.*/\1/'
}

test_contract_slot_exists() {
  local f="$1" scenario_id="$2"
  grep -qE "^### ${scenario_id}[[:space:]]*->" "$f" 2>/dev/null
}

check_module_map_present() {
  local f="$1" ids
  ids="$(module_ids "$f")"
  [ -n "$ids" ]
}

check_overlap() {
  local f="$1" id path entries=()
  local ids
  ids="$(module_ids "$f")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      entries+=("$path|$id")
    done < <(module_files "$f" "$id")
  done <<< "$ids"

  local i j path_i path_j id_i id_j
  for ((i = 0; i < ${#entries[@]}; i++)); do
    path_i="${entries[$i]%%|*}"
    id_i="${entries[$i]#*|}"
    for ((j = i + 1; j < ${#entries[@]}; j++)); do
      path_j="${entries[$j]%%|*}"
      id_j="${entries[$j]#*|}"
      if [ "$path_i" = "$path_j" ] && [ "$id_i" != "$id_j" ]; then
        echo "plan-validate: overlap de arquivos — $path_i em $id_i, $id_j" >&2
        return 1
      fi
    done
  done
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

validate_plan() {
  local f="$1"

  if ! check_module_map_present "$f"; then
    echo "plan-validate: module map vazio" >&2
    return 2
  fi

  if ! check_overlap "$f"; then
    return 2
  fi

  if ! check_scenario_layers "$f"; then
    return 2
  fi

  if ! check_dependency_refs "$f"; then
    return 2
  fi

  if ! check_cycle "$f"; then
    return 2
  fi

  return 0
}

main() {
  local positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --*)
        usage
        exit 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  [ "${#positional[@]}" -eq 1 ] || { usage; exit 1; }
  local plan_file="${positional[0]}"

  if [ ! -f "$plan_file" ]; then
    echo "plan-validate: plan file not found: $plan_file" >&2
    exit 1
  fi

  if validate_plan "$plan_file"; then
    echo "plan-validate: plan válido"
    exit 0
  else
    exit 2
  fi
}

main "$@"
