# SPEC-12 — Constituição de projeto normativa

**Eixo:** assertividade
**Fonte da ideia:** spec-kit `/constitution` (princípios imutáveis, cláusula de supremacia,
violação de MUST = CRITICAL automático, desvio exige justificativa escrita).

## Contexto

`ship/config.md` é descritivo (stack, convenções), não **normativo**. Não há princípios que o
`ship:review` e `ship:analyze` tratem como não-negociáveis.

## O que fazer

Adicionar uma seção `## Principles` (ou arquivo dedicado) com princípios versionados.
`ship:review` e `ship:analyze` tratam violação de princípio MUST como CRITICAL automático;
desvio exige justificativa escrita (à la Complexity Tracking).

## Critérios de aceite

- Princípios versionados com data de ratificação/emenda.
- Violação de MUST → gate FAIL automático.
- Desvio registrado com justificativa no artefato de qualidade.
