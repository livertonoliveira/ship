# SPEC-16 — Descrições de skill só com gatilhos

**Eixo:** assertividade
**Fonte da ideia:** superpowers (achado empírico: quando a description resume o workflow, o
agente às vezes segue a description em vez de ler o skill — fizeram 1 review em vez de 2).

## Contexto

Se o `description` de um skill resume o processo, o modelo pode agir sobre o resumo em vez de ler
o conteúdo completo.

## O que fazer

Auditar os frontmatters dos 18 skills do Ship: `description` deve conter **apenas condições de
disparo**, nunca resumo do workflow.

## Critérios de aceite

- Nenhum `description` descreve passos do processo.
- Todos os `description` são puramente sobre quando invocar.
