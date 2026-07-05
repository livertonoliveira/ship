# SPEC-07 — Passo de clarificação com orçamento no `ship:spec`

**Eixo:** assertividade (upstream)
**Fonte da ideia:** spec-kit `/clarify` (taxonomia de 9 categorias, máx. 5 perguntas por
Impacto × Incerteza, resposta recomendada, marcadores `[NEEDS CLARIFICATION]`).

## Contexto

Spec ambígua é a raiz de quase todo drift que os 11 guardas do Ship tentam pegar *depois*. Matar
a ambiguidade na origem é muito mais barato.

## O que fazer

Adicionar ao `ship:spec` um passo de clarificação:
- varrer a spec contra taxonomia de ambiguidade (escopo funcional, modelo de dados, UX,
  atributos não-funcionais, integrações, edge cases, tradeoffs, terminologia, sinais de
  conclusão);
- **máximo 5 perguntas**, uma por vez, ranqueadas por Impacto × Incerteza;
- múltipla escolha com **resposta recomendada** (aceite em uma palavra);
- integrar cada resposta de volta na spec imediatamente;
- marcar ambiguidades não resolvidas com `[NEEDS CLARIFICATION]` (greppável).

## Critérios de aceite

- Nunca mais que 5 perguntas por sessão de clarificação.
- Cada resposta é escrita de volta na seção relevante da spec.
- `[NEEDS CLARIFICATION]` restantes bloqueiam ou avisam antes de criar issues no Linear.
