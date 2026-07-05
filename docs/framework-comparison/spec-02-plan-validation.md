# SPEC-02 — Validação determinística de `plan.md` antes de develop/test

**Eixo:** assertividade
**Fonte da ideia:** OpenSpec (`openspec validate --strict`, gramática estrita parseada por CLI).

## Contexto

`ship:plan` gera `plan.md` (module map + test contract), mas **nada valida** o artefato antes
de develop e test o consumirem. Se o module map tem arquivos sobrepostos entre módulos,
cenários órfãos ou ciclos de dependência, os workers descobrem reativamente — gastando tokens
para falhar.

## O que fazer

Criar `src/hooks/plan-validate.sh` que o orquestrador roda após o planner concluir:
- module map não-vazio;
- módulos disjuntos (nenhum arquivo aparece em 2+ módulos);
- todos os cenários (AC/SC) mapeados para uma camada de teste;
- sem ciclos de dependência entre módulos.

Falha → exit code 2 → orquestrador re-roda o planner ou pergunta ao usuário. Zero IA na
validação (só parsing).

## Critérios de aceite

- `plan.md` malformado falha deterministicamente antes de qualquer worker rodar.
- Detecção de: overlap de arquivos, cenário órfão, ciclo, module map vazio.
- Mensagem de erro nomeia o problema específico (não "plan inválido").
- Integrado ao fluxo do `ship:run` como gate pós-planner.
