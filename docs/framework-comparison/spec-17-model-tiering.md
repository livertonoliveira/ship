# SPEC-17 — Model tiering explícito com Haiku para trabalho de varredura

**Eixo:** custo + velocidade
**Fonte da ideia:** superpowers (*"modelos mais baratos levam 2–3× mais turnos... contagem de
turnos vence preço de token"*; "sempre especifique o modelo explicitamente").

## Contexto

Vários workers rodam em Sonnet sem necessidade de raciocínio pesado. Omitir o modelo no dispatch
herda silenciosamente o modelo caro da sessão.

## O que fazer

Rotear para Haiku o trabalho de transcrição/varredura (workers de audit, hygiene cleanup,
geração de teste a partir de contrato já pronto — o contrato existe justamente para tirar
raciocínio do worker). Manter Sonnet onde há decisão de arquitetura. **Sempre especificar o
modelo explicitamente** em cada dispatch.

## Critérios de aceite

- Nenhum dispatch sem modelo explícito.
- Workers de varredura em Haiku; decisão em Sonnet.
- Sem regressão de qualidade nos gates (validar via
  [SPEC-05](spec-05-pressure-testing.md) se possível).

## Cuidado

Não trocar para Haiku onde o custo de turnos extras supera a economia de token (medir, não
assumir).
