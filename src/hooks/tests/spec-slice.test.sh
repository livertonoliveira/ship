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

test_an_uncited_proposal_falls_back() {
  local name="exit 3 when the issue cites no requirement the Proposal defines, so the model stages it"
  local dir rc=0
  dir="$(mktemp -d)"; fixture "$dir"
  printf '# MOB-2 — Outra\n\nSem requisito.\n' > "$dir/issue.md"
  bash "$SLICE" "$dir/issue.md" "$dir/proposal.md" "$dir/spec.md" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 3 ] && [ ! -e "$dir/spec.md" ]; then log_pass "$name"; else log_fail "$name (rc=$rc)"; fi
  rm -rf "$dir"
}

test_the_cited_block_is_copied_whole
test_the_rest_is_a_one_line_index
test_a_long_line_is_cut_on_a_word_and_stays_utf8
test_an_uncited_proposal_falls_back

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
