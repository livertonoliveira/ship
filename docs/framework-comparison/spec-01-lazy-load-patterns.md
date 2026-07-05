# SPEC-01 — Lazy-load dos patterns pesados do orquestrador

**Eixo:** tokens + velocidade
**Fonte da ideia:** superpowers ("`@` links force-load 200k+ de contexto antes de você
precisar"), mecanismo `@@ship/` já existente no Ship.

## Contexto

`run/SKILL.md` cresce 77% no build por inlinar patterns via `@ship/`:
- `run-context.md` (236 linhas)
- `gates.md` (121 linhas)
- `severity.md` (122 linhas)
- `lazy-load-findings.md` (42 linhas)

Esses ~15,8K tokens ficam **residentes** no contexto do orquestrador e são re-lidos a cada
turno durante todo o pipeline — o processo mais longo da execução.

## O que fazer

Converter os patterns pesados de `@ship/` (inline no build) para `@@ship/` (lazy via
`${CLAUDE_SKILL_DIR}`, já suportado no `build.js`). O orquestrador lê cada pattern apenas no
momento em que a fase que o usa é despachada. Manter inline apenas patterns leves
(`parallelism.md` 8 linhas, `language.md` 12 linhas, `load-artifacts.md` 15 linhas).

## Critérios de aceite

- `run/SKILL.md` compilado cai de ~1.206 para ≤ ~750 linhas.
- Patterns `run-context`, `gates`, `severity` carregados sob demanda, não no header.
- Comportamento do pipeline inalterado (mesmos gates, mesmas fases).
- Custo de instrução residente do orquestrador ≤ ~9K tokens.

## Notas

Maior ganho combinado tokens+velocidade; infra de build já existe. Ganho de velocidade porque
instrução residente = latência por turno.
