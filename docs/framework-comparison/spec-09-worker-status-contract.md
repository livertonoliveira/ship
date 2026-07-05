# SPEC-09 — Contrato de status fechado para workers

**Eixo:** assertividade
**Fonte da ideia:** superpowers (implementer reporta `DONE / DONE_WITH_CONCERNS /
NEEDS_CONTEXT / BLOCKED`, cada um com handler prescrito).

## Contexto

Workers do Ship escrevem `phase-status` em formato livre, deixando uma zona cinzenta de
"terminou mais ou menos" que o orquestrador precisa interpretar.

## O que fazer

Definir um enum fechado de status de conclusão para cada worker (develop, test, quality), com um
handler prescrito por estado no orquestrador (ex.: `NEEDS_CONTEXT` → re-dispatch com contexto
adicional; `BLOCKED` → escala ao usuário).

## Critérios de aceite

- Todo worker termina reportando exatamente um estado do enum.
- Orquestrador tem ramo determinístico por estado.
- Estados fora do enum são rejeitados (gate).
