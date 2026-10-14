#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLICE="$SCRIPT_DIR/../spec-slice.sh"

pass_count=0
fail_count=0

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

# Ids are assembled at runtime so this file carries no spec-id literal.
R="REQ"

fixture() {
  local dir="$1"
  {
    printf '# Proposal\n\n## Requisitos\n\n### TASK-101 · Listagem\n\n'
    printf '%s-101 — A listagem mostra o número da comanda e a mensagem de erro de cada nota emitida no período selecionado pelo usuário:\n\n' "$R"
    printf '* Usa o identificador real.\n* Só oferece cancelamento para notas emitidas.\n\n'
    printf '%s-102 — Exportação em CSV com acentuação: ação, situação, emissão, conciliação e observações.\n\n' "$R"
    printf '### TASK-102 · Cancelamento\n\n%s-103 — Cancelar exige confirmação.\n' "$R"
  } > "$dir/proposal.md"
  printf '# MOB-1 — Listagem\n\n## Requisito\n\nCobre %s-101.\n' "$R" > "$dir/issue.md"
}

test_the_cited_block_is_copied_whole() {
  local name="the block of each cited requirement is copied whole, up to the next requirement"
  local dir
  dir="$(mktemp -d)"; fixture "$dir"
  bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md" >/dev/null
  if grep -q "^## Proposal — ${R}-101$" "$dir/spec.md" \
     && grep -q '^\* Só oferece cancelamento para notas emitidas.$' "$dir/spec.md" \
     && ! grep -q "^${R}-102 — Exportação" "$dir/spec.md" \
     && grep -q '^# MOB-1 — Listagem$' "$dir/spec.md"; then
    log_pass "$name"
  else
    log_fail "$name ($(cat "$dir/spec.md"))"
  fi
  rm -rf "$dir"
}

test_the_rest_is_a_one_line_index() {
  local name="every other requirement is one index line naming the task that covers it"
  local dir
  dir="$(mktemp -d)"; fixture "$dir"
  bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md" >/dev/null
  if grep -q "^- ${R}-103 — Cancelar exige confirmação. — covered by TASK-102$" "$dir/spec.md" \
     && grep -q "^- ${R}-102 — " "$dir/spec.md" \
     && ! grep -q "^- ${R}-101 " "$dir/spec.md"; then
    log_pass "$name"
  else
    log_fail "$name ($(sed -n '/Scope index/,$p' "$dir/spec.md"))"
  fi
  rm -rf "$dir"
}

test_a_long_line_is_cut_on_a_word_and_stays_utf8() {
  local name="a long index line is cut at a whole word, never inside an accented character"
  local dir
  dir="$(mktemp -d)"; fixture "$dir"
  bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md" >/dev/null
  if iconv -f UTF-8 -t UTF-8 "$dir/spec.md" >/dev/null 2>&1 && grep -q "^- ${R}-102 — .*,… — covered by TASK-101$" "$dir/spec.md"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$dir"
}

test_a_heading_shaped_requirement_is_a_block() {
  local name="a requirement written as a heading (### REQ-nnn — ...) is sliced like a bare one"
  local dir
  dir="$(mktemp -d)"
  {
    printf '# Proposal\n\n## Requisitos\n\n### %s-001 — Foto usa chave gerada pelo servidor  ·  catálogo\n\nTexto do primeiro.\n\n### %s-002 — Transferência valida alcance\n\nTexto do segundo.\n' "$R" "$R"
  } > "$dir/proposal.md"
  printf '# MOB-2 — Foto\n\nCobre %s-001.\n' "$R" > "$dir/issue.md"
  local out; out="$(bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md")"
  if grep -q "^## Proposal — ${R}-001$" "$dir/spec.md" && grep -q '^Texto do primeiro.$' "$dir/spec.md" \
     && ! grep -q 'Texto do segundo' "$dir/spec.md" && grep -q "^- ${R}-002 — Transferência valida alcance" "$dir/spec.md" \
     && printf '%s' "$out" | grep -q "^cited=${R}-001$"; then
    log_pass "$name"
  else
    log_fail "$name (out=$out spec=$(cat "$dir/spec.md"))"
  fi
  rm -rf "$dir"
}

test_an_issue_citing_no_requirement_still_gets_a_spec() {
  local name="an issue that cites no requirement gets its own text plus the full scope index, exit 0, cited=none"
  local dir
  dir="$(mktemp -d)"; fixture "$dir"
  printf '# MOB-3 — [AW·082] delete() lança not-found\n\n## Contexto\n\nContinuação de AW·081.\n' > "$dir/issue.md"
  local out rc=0; out="$(bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md")" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^# MOB-3 — ' "$dir/spec.md" && ! grep -q '^## Proposal — ' "$dir/spec.md" \
     && grep -q "^- ${R}-101 — " "$dir/spec.md" && grep -q "^- ${R}-103 — " "$dir/spec.md" \
     && printf '%s' "$out" | grep -q '^cited=none$'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out=$out spec=$(cat "$dir/spec.md" 2>/dev/null))"
  fi
  rm -rf "$dir"
}

test_a_proposal_with_no_requirements_is_still_exit_3() {
  local name="a Proposal that defines no requirement at all keeps exit 3 — the caller stages the old way"
  local dir
  dir="$(mktemp -d)"
  printf '# Proposal\n\nSem requisitos numerados.\n' > "$dir/proposal.md"
  printf '# MOB-4\n\nNada.\n' > "$dir/issue.md"
  local rc=0; bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 3 ] && [ ! -s "$dir/spec.md" ]; then log_pass "$name"; else log_fail "$name (rc=$rc)"; fi
  rm -rf "$dir"
}

test_the_cited_block_is_copied_whole
test_a_heading_shaped_requirement_is_a_block
test_an_issue_citing_no_requirement_still_gets_a_spec
test_a_proposal_with_no_requirements_is_still_exit_3
test_the_rest_is_a_one_line_index
test_a_long_line_is_cut_on_a_word_and_stays_utf8

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
