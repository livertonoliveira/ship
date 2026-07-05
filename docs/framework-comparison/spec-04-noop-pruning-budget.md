# SPEC-04 — Poda "no-op" + budget de palavras no build

**Eixo:** tokens
**Fonte da ideia:** Pocock (teste do no-op; "delete a frase inteira, não apode palavras") +
superpowers (`wc -w`, budgets verificados: skills frequentes <200 palavras, outros <500).

## Contexto

`src/` tem 8.502 linhas. Muitas instruções são no-ops: linhas que o modelo já obedece por
default ("leia o arquivo antes de editar"). O teste do Pocock: *"essa linha muda o
comportamento versus o default? Se não, você paga contexto para dizer nada."*

## O que fazer

1. Passar o filtro de no-op em todo `src/skills/**` e `src/agents/**`; quando uma frase falha o
   teste, deletar a frase inteira.
2. Substituir parágrafos por **leading words** — palavras pré-treinadas fortes ("surgical",
   "disjoint", "tracer bullet") que ancoram uma região de comportamento.
3. Adicionar ao `build.js` um gate de budget: falhar o build se um SKILL.md compilado estourar
   um teto de palavras (ex.: orquestrador ≤ 8K palavras, skills de fase ≤ 2K).

## Critérios de aceite

- Redução de 30–40% no total de linhas de instrução, sem perda de capacidade.
- Build falha (exit 1) se algum skill compilado passar do budget.
- Nenhuma mudança de comportamento observável nos pipelines de teste.

## Cuidado

Achado empírico do superpowers: proibições pesadas podem performar **pior** que nenhuma
instrução em problemas de "formato de saída". Proibição serve para *rule-skipping*; receita
positiva serve para *shaping*. Podar com esse critério em mente. Idealmente validar via
[SPEC-05](spec-05-pressure-testing.md).
