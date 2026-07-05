# SPEC-03 — Consolidação de status e evidence gate em script

**Eixo:** assertividade + velocidade
**Fonte da ideia:** spec-kit (tudo mecânico roda em bash, devolve JSON compacto).

## Contexto

Três operações mecânicas hoje são executadas em prosa pelo orquestrador:
1. consolidação de `phase-status-*.md` → `phase-status.md`;
2. evidence gate (todo arquivo tocado pelo develop tem ≥ 1 teste?);
3. interseção do re-run cirúrgico (arquivos alterados pelo fix ∩ escopo de cada fase).

Cada uma é fonte potencial de drift e custa tokens de raciocínio.

## O que fazer

Extrair cada uma para um script bash de ~20 linhas que roda em ms e devolve resultado
estruturado (JSON ou markdown row). O orquestrador chama o script e age sobre a saída.

## Critérios de aceite

- Consolidação de status é determinística (mesmo input → mesmo `phase-status.md`).
- Evidence gate reporta lista exata de arquivos sem teste.
- Re-run cirúrgico computa o conjunto de fases via interseção de hashes, sem julgamento do
  modelo.
- Nenhuma regressão nos gates existentes.
