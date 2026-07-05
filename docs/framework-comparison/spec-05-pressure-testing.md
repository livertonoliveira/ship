# SPEC-05 — Harness de pressure-testing dos skills

**Eixo:** assertividade (meta)
**Fonte da ideia:** superpowers `writing-skills` — *"escrever skills É TDD aplicado a
documentação de processo"*.

## Contexto

O Ship nunca validou empiricamente se suas instruções de 15K tokens produzem comportamento
melhor que versões menores. O superpowers roda subagentes sob pressão combinada (tempo + sunk
cost + exaustão), captura racionalizações *verbatim* e contra-ataca no texto — sempre com um
**controle sem instrução** ("se o controle não exibe a falha, não escreva a instrução").

## O que fazer

Como `plugins/` é buildado de `src/`, montar um harness de regressão comportamental:
- cenários fixos de entrada (spec + código);
- rodar o skill via subagente;
- verificar os artefatos produzidos contra asserções (schema de `plan.md`, ausência de spec
  IDs em código, gate correto).

Incluir sempre um braço de controle sem a instrução sob teste, para provar que a instrução muda
o comportamento.

## Critérios de aceite

- Suite reproduzível que roda N reps por skill e reporta variância.
- Cada asserção mapeia para um comportamento observável (não julgamento subjetivo).
- Documenta pelo menos um caso onde uma instrução foi removida por não mudar o comportamento
  (validando a poda da [SPEC-04](spec-04-noop-pruning-budget.md)).

## Notas

É o que separa o superpowers de todo o resto: evolução medida, não "parece melhor".
