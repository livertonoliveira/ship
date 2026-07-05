# Ship — Análise comparativa e roadmap de melhorias

> Estudo comparativo do Ship contra quatro frameworks de referência, com um catálogo de
> oportunidades de melhoria. Cada oportunidade está num arquivo próprio, escrita como
> **candidata a spec** (`/ship:spec`), para ser trabalhada isoladamente depois.

**Data:** 2026-07-05
**Frameworks comparados:**
- [obra/superpowers](https://github.com/obra/superpowers) — metodologia completa de dev para agentes
- [mattpocock/skills](https://github.com/mattpocock/skills/tree/main/skills/productivity) — skills mínimas e compostáveis
- [Fission-AI/OpenSpec](https://github.com/Fission-AI/OpenSpec/) — specs em delta, markdown puro
- [github/spec-kit](https://github.com/github/spec-kit) — spec como blueprint executável

---

## 1. Onde o Ship está hoje

O Ship é o mais **completo em orquestração** dos cinco frameworks: nenhum outro tem pipeline
paralelo com gates de qualidade, re-run cirúrgico por interseção de arquivos e hooks
determinísticos de higiene. É também o único com integração nativa a um tracker (Linear).

Suas fraquezas relativas:

1. **Peso de contexto.** O `/ship:run` compilado carrega ~15,8K tokens só de instrução
   (1.206 linhas). O build inline (`@ship/`) infla o skill em 77%. O orquestrador equivalente do
   superpowers usa ~3K tokens; o skill mediano do Pocock tem ~100 palavras.
2. **Validação de artefatos intermediários em prosa.** `plan.md`, evidence gate, consolidação
   de status e re-run cirúrgico são executados "na cabeça" do modelo, não por scripts
   determinísticos — o oposto do que OpenSpec e spec-kit fazem.
3. **Ausência de fonte de verdade viva.** Não há um `specs/` que descreva o comportamento
   acumulado do sistema; cada feature é greenfield-por-task.
4. **Prompts nunca validados empiricamente.** Não sabemos se 15K tokens de instrução produzem
   comportamento melhor que uma versão de 5K.

### Posicionamento resumido

| | Ship | superpowers | Pocock skills | OpenSpec | spec-kit |
|---|---|---|---|---|---|
| Filosofia | Pipeline completo com gates | Metodologia blindada contra agente que racionaliza | Primitivas mínimas, usuário no controle | Camada de spec em deltas | Spec como blueprint executável |
| Peso típico de skill | 1,6K–15,8K tokens | 400–1.500 palavras | **20–500 palavras** | templates pequenos + CLI | prompts 7–20KB |
| Determinismo fora do LLM | hooks bash | scripts de handoff | nenhum | **CLI valida/mergeia specs** | **scripts bash/PS** |
| Assertividade | 11 guardas estruturais | Iron Laws + pressure-testing | critérios de conclusão verificáveis | gramática + `validate --strict` | 3 gates (constitution, clarify, analyze) |
| Paralelismo | **O melhor** | conservador | background agents | deltas paralelos | tasks `[P]` |

O Ship já vence em paralelismo, guardas de drift e integração Linear. As melhorias abaixo
atacam custo de contexto, validação determinística, engenharia empírica de prompts e memória de
longo prazo.

---

## 2. Índice de melhorias (candidatas a spec)

Cada item é auto-contido no seu arquivo. Eixo = dimensão da sua pergunta original
(assertividade / tokens / velocidade / outras oportunidades).

| # | Melhoria | Eixo | Fonte da ideia |
|---|---|---|---|
| [01](spec-01-lazy-load-patterns.md) | Lazy-load dos patterns pesados do orquestrador | tokens + velocidade | superpowers |
| [02](spec-02-plan-validation.md) | Validação determinística de `plan.md` | assertividade | OpenSpec |
| [03](spec-03-status-scripts.md) | Consolidação de status + evidence gate em script | assertividade + velocidade | spec-kit |
| [04](spec-04-noop-pruning-budget.md) | Poda "no-op" + budget de palavras no build | tokens | Pocock + superpowers |
| [05](spec-05-pressure-testing.md) | Harness de pressure-testing dos skills | assertividade (meta) | superpowers |
| [06](spec-06-living-specs-delta.md) | `ship/specs/` vivo com specs em delta | memória + paralelismo | OpenSpec |
| [07](spec-07-clarify-budget.md) | Clarificação com orçamento no `ship:spec` | assertividade (upstream) | spec-kit |
| [08](spec-08-coverage-matrix.md) | Matriz de cobertura quantificada no `ship:analyze` | assertividade | spec-kit |
| [09](spec-09-worker-status-contract.md) | Contrato de status fechado para workers | assertividade | superpowers |
| [10](spec-10-progress-ledger.md) | Ledger de progresso resistente à compactação | assertividade + custo | superpowers |
| [11](spec-11-converge-brownfield.md) | `ship:converge` para adoção brownfield | adoção | spec-kit |
| [12](spec-12-project-constitution.md) | Constituição de projeto normativa | assertividade | spec-kit |
| [13](spec-13-dedup-agents.md) | Dedup de agentes de teste e audit | tokens + manutenção | auditoria interna |
| [14](spec-14-file-handoff.md) | Handoff por arquivo em vez de injeção inline | tokens | superpowers |
| [15](spec-15-english-checklists.md) | Checklists "testes unitários de inglês" | assertividade | spec-kit |
| [16](spec-16-trigger-only-descriptions.md) | Descrições de skill só com gatilhos | assertividade | superpowers |
| [17](spec-17-model-tiering.md) | Model tiering explícito (Haiku p/ varredura) | custo + velocidade | superpowers |
| [18](spec-18-conditional-hygiene-secrets.md) | Sweep de higiene condicional + secrets no hook | velocidade + segurança | auditoria interna |
| [19](spec-19-skill-lifecycle.md) | Ciclo de vida e disciplina de poda de skills | manutenção | Pocock |

---

## 3. Ordem de ataque sugerida

Priorizada por relação impacto/esforço e por dependências:

1. **SPEC-01** (lazy-load patterns) — maior ganho tokens+velocidade, cirúrgico no `build.js`.
2. **SPEC-02 + SPEC-03** (validação de plan + consolidação em script) — assertividade
   determinística onde hoje há prosa; ambos mexem em hooks.
3. **SPEC-04** (poda no-op + budget no build) — corte estrutural de 30–40% do texto, com gate
   de CI.
4. **SPEC-05** (harness de pressure-testing) — habilita medir SPEC-04 e SPEC-17; transforma a
   evolução do Ship em algo medido.
5. **SPEC-06** (`ship/specs/` vivo) — maior mudança conceitual, maior valor composto; melhor
   feita depois que o harness existe para proteger contra regressão.

Os demais (SPEC-07 a SPEC-19) podem ser encaixados conforme prioridade de produto — vários são
independentes e de baixo esforço (SPEC-16, SPEC-18, SPEC-13).

---

## 4. Ideias que valem citar mesmo sem virar spec agora

- **Convergência de OpenSpec e superpowers em fundamentos:** descrições só com gatilhos,
  progressive disclosure, brainstorm/grill antes de código, TDD, "delete não apode". Ambos
  chegaram nisso independentemente — sinal de que são princípios reais, não modinha.
- **Registro oposto de assertividade:** superpowers assume que o agente vai trapacear e blinda
  cada regra ("se há 1% de chance de um skill se aplicar, você ABSOLUTAMENTE DEVE invocá-lo");
  Pocock assume que cada token extra dilui o sinal e poda até o osso ("você paga contexto para
  dizer nada"). O próprio meta-skill do superpowers tem evidência empírica a favor do instinto
  do Pocock. O Ship hoje está no extremo verboso sem a evidência — daí a importância da SPEC-05.
- **"Leading words"** (Pocock): uma palavra pré-treinada forte ancora uma região inteira de
  comportamento nos menores tokens possíveis. É a técnica de compressão mais subestimada e cabe
  em toda a base do Ship.
