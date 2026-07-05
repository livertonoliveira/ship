# SPEC-08 — Matriz de cobertura quantificada no `ship:analyze`

**Eixo:** assertividade
**Fonte da ideia:** spec-kit `/analyze` (tabela requirement→task, cobertura %, 6 passes de
detecção, CRITICAL bloqueia implementação).

## Contexto

`ship:analyze` já faz correlação Jaccard spec↔code↔tests, mas o resultado é um julgamento
PASS/WARN/FAIL do modelo. Emitir uma **matriz quantificada** torna o gate auditável.

## O que fazer

Produzir, além do gate:
- tabela requirement → task/código/teste com **% de cobertura**;
- lista nomeada de requirements com zero cobertura (gaps);
- lista de tasks/código órfãos (sem requirement);
- 6 passes de detecção: duplicação, ambiguidade (termos vagos sem threshold), subespecificação,
  violação de princípios, gaps de cobertura, inconsistência de terminologia.

## Critérios de aceite

- Saída inclui matriz de cobertura com percentual.
- Gaps e órfãos nomeados explicitamente (arquivo/requirement).
- Gate PASS/WARN/FAIL derivado da matriz, não de impressão.
