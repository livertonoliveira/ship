# SPEC-13 — Deduplicação de agentes de teste e audit

**Eixo:** tokens + manutenção
**Fonte da ideia:** auditoria interna do Ship + filosofia "sediment" do Pocock.

## Contexto

- `ship-test-unit.md`, `ship-test-integration.md`, `ship-test-e2e.md` são **95% idênticos**
  (~116–124 linhas cada).
- Workers de audit repetem ~40 linhas de boilerplate × 3 agentes × 6 tipos (~720 linhas).

## O que fazer

Como `plugins/` é gerado, extrair templates comuns + substituição no build:
- `ship-test-common.md` com as seções compartilhadas; agentes de camada viram ~20–30 linhas de
  override.
- `audit-worker-pattern.md` com o frame compartilhado; audit skills passam heurísticas + idioma
  inline.

## Critérios de aceite

- Agentes de teste sem duplicação de estrutura (só override de camada).
- Workers de audit sem boilerplate repetido.
- Comportamento idêntico ao atual (build produz agentes equivalentes).
- ~1.300 linhas removidas do `src/`.
