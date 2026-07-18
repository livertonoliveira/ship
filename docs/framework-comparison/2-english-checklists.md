# SPEC-15 — Checklists como "testes unitários de inglês"

**Eixo:** assertividade (qualidade da spec)
**Fonte da ideia:** spec-kit `/checklist` (valida a *qualidade da spec*, nunca a implementação;
padrões proibidos).

## Contexto

Não há gate que valide a **qualidade do documento de spec** antes de gerar issues.

## O que fazer

Adicionar ao fim do `ship:spec` uma geração de checklist que valida a spec ("a interação do
botão está claramente especificada? [Clarity, §FR-1]"), **nunca** a implementação. Padrões
proibidos: verbos Verify/Test/Confirm + comportamento do sistema (isso é item de implementação,
rejeitado). Dimensões: completude, clareza, consistência, mensurabilidade, cobertura, rigor
não-funcional, rastreabilidade, resolução de ambiguidade.

## Critérios de aceite

- Checklist gerado valida qualidade da spec, não implementação.
- Itens no formato proibido são rejeitados na geração.
- Roda como gate barato antes de criar issues no Linear.
