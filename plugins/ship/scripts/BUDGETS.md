# Budget de palavras dos SKILL.md

O build (`plugins/ship/scripts/build.js`) percorre `src/skills/**/SKILL.md` e `src/agents/*.md`, resolve as refs (`@ship/...`) e escreve o compilado em `plugins/ship/`. Após `buildSkills()` gravar cada SKILL.md compilado, um gate de verificação conta as palavras do conteúdo já com as refs substituídas (`countWords`) e compara com um teto por tier (`checkBudget`), lendo os valores de `plugins/ship/scripts/budgets.js`. Qualquer skill que exceda o teto do seu tier interrompe o build com `process.exit(1)`.

## Tiers e tetos

Os tetos são definidos em `plugins/ship/scripts/budgets.js` (fonte da verdade).

| Tier | Teto (palavras) | Skills |
|------|------------------|--------|
| orchestrator | 8000 | `run` |
| heavy | 4000 | `spec`, `pr` |
| phase | 3000 | `test`, `develop`, `plan`, `homolog`, `init`, `audit:run`, `perf`, `security`, `review`, `analyze` |
| small | 900 | `audit:backend`, `audit:database`, `audit:frontend`, `audit:security`, `audit:tests` |

## Racional

O que o modelo paga em custo de contexto é o SKILL.md **compilado** — com as refs já resolvidas inline — não o arquivo fonte em `src/skills/`. Por isso o gate mede a saída de `buildSkills()`, e não o conteúdo de `src/**`.

Os tetos por tier foram fixados como o tamanho atingido pelo skill após uma rodada de poda de no-ops e boilerplate, mais um headroom de aproximadamente 10–15%. Isso permite crescimento orgânico moderado sem exigir ajuste de teto a cada pequena mudança, ao mesmo tempo em que impede que um skill infle indefinidamente sem revisão.

## Quando o build falha por budget

Se `build.js` reportar que um skill excedeu seu teto, siga esta ordem:

1. **Tentar podar primeiro.** Remover no-ops, comprimir parágrafos em leading-words, consolidar boilerplate duplicado extraindo-o para `src/patterns/*.md` e referenciando via `@ship/...`. O objetivo é reduzir o word count sem alterar o comportamento observável do skill.
2. **Só depois de esgotar a poda razoável, ajustar o teto.** Alterar o valor do tier correspondente em `plugins/ship/scripts/budgets.js`, ou adicionar uma entrada explícita ao skill em `WORD_BUDGETS` se ele merecer um teto próprio fora do tier padrão. Justifique o motivo do aumento na descrição do PR.

## Skills sem entrada explícita

Qualquer `skillKey` que não tenha uma entrada explícita em `WORD_BUDGETS` cai no fallback `DEFAULT_BUDGET` (1000 palavras). Isso cobre skills novos criados sem uma decisão deliberada de tier — o objetivo é forçar uma escolha consciente de tier assim que o skill crescer além desse teto padrão.
