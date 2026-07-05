# SPEC-14 — Handoff por arquivo em vez de injeção inline

**Eixo:** tokens
**Fonte da ideia:** superpowers (*"tudo que você cola num dispatch fica residente e é re-lido a
cada turno"*; scripts `task-brief`, `review-package` escrevem em arquivo e passam o path).

## Contexto

O Ship usa scratch dir bem, mas ainda **fatia e injeta inline** (plan slices por camada, diff
por categoria OWASP), o que mantém os bytes residentes no contexto do orquestrador.

## O que fazer

Criar `slice.sh` que escreve a fatia (plan por camada, diff por categoria) em um arquivo no
scratch dir e passa apenas o path para o worker.

## Critérios de aceite

- Nenhuma fatia grande injetada inline no dispatch.
- Workers recebem paths, leem sob demanda.
- Contexto residente do orquestrador reduzido.
