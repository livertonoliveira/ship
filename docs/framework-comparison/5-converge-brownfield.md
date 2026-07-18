# SPEC-11 — `ship:converge` para adoção brownfield

**Eixo:** oportunidade de adoção
**Fonte da ideia:** spec-kit `/converge` (avalia codebase existente contra spec, emite gap como
tasks).

## Contexto

O Ship assume greenfield-por-task. Projetos legados não têm porta de entrada — provavelmente o
maior bloqueador de adoção por terceiros.

## O que fazer

Criar `ship:converge`: dado um codebase existente e uma spec/`ship/specs/`, diferenciar a
realidade contra a spec e emitir o gap como tasks acionáveis.

## Critérios de aceite

- Roda contra um repo sem histórico Ship.
- Produz lista de tasks que fecham o gap spec↔código.
- Integra com `ship/specs/` ([SPEC-06](spec-06-living-specs-delta.md)) quando presente.
