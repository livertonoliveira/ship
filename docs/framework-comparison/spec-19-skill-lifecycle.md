# SPEC-19 — Ciclo de vida e disciplina de poda de skills

**Eixo:** manutenção
**Fonte da ideia:** Pocock (pasta `deprecated/`, versionamento via changesets, vocabulário
*sediment/sprawl/no-op*).

## Contexto

Os 18 patterns do Ship correm risco de *sediment*: camadas obsoletas que ninguém remove porque
adicionar parece seguro e remover parece arriscado.

## O que fazer

Estabelecer disciplina: pasta para skills/patterns deprecados, revisão periódica com o teste de
no-op, e critério de poda em nível de frase.

## Critérios de aceite

- Processo documentado de deprecação e poda.
- Pelo menos uma passada inicial removendo patterns/no-ops mortos.
