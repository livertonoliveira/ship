# SPEC-10 — Ledger de progresso resistente à compactação

**Eixo:** assertividade + custo
**Fonte da ideia:** superpowers (*"controllers que perderam o lugar re-despacharam sequências
inteiras de tasks já completas — a falha mais cara observada"*).

## Contexto

`dispatch-log.md` registra dispatches, mas nada instrui o orquestrador a confiar no ledger acima
da própria memória após compaction/resume.

## O que fazer

Adicionar instrução explícita e um procedimento de resume: após compaction, reconstruir o estado
a partir de `dispatch-log.md` + `phase-status.md` + `git log`, e **confiar no ledger acima da
memória**. Detectar runs interrompidos (dispatch row sem phase-status row → decisão resume vs
restart).

## Critérios de aceite

- Resume nunca re-despacha uma fase já concluída (linha em `phase-status.md`).
- Procedimento documentado no `ship:run`.
- Teste de interrupção/resume valida o comportamento.
