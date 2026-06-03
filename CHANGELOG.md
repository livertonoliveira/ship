# Changelog

Histórico reconstruído a partir do versionamento automático (`plugin.json`) e dos commits de cada release. Versões em ordem decrescente.

## 2.7.7 — 2026-06-03

### Docs
- Adicionada a primeira entrada de CHANGELOG ao repositório (#79).
- Release de documentação, sem mudança funcional.

## 2.7.6 — 2026-06-03

### Fixes
- Orquestradores `develop`/`test` não fazem mais "narrate-and-return" (#78).
- Rodando em Haiku e sem Edit/Write, eles só produzem trabalho despachando workers via Agent tool.
- Modo de falha: narrar o plano e retornar status de sucesso sem despachar worker, deixando a working tree intocada.
- Prompts endurecidos: bloco CRITICAL tratando narrate-and-return como hard failure.
- Seção 3 marcada como MANDATORY ACTION.
- Self-check obrigatório antes de retornar (contagem de workers vs. módulos, `git diff --stat`).

## 2.7.5 — 2026-06-02

### Fixes
- Diff do pipeline ancorado na working tree, não no HEAD (#77).
- `diff.md` era capturado uma vez no passo 0.5 (antes do develop) com range `origin/main...HEAD`.
- Como `ship:develop` integra na working tree sem commitar, perf/security/review liam um diff sem a implementação.
- Em branch nova o diff classificava como trivial e toda fase de qualidade era silenciosamente pulada.
- Novo passo 2.5: após o develop, recaptura `diff.md` sobre a working tree pós-develop e recomputa `diff-class.txt`.
- Captura via `git add -A -N` + diff contra o merge-base, incluindo untracked, sem precisar commitar.

## 2.7.4 — 2026-06-02

### Fixes
- Spec IDs e Linear issue keys param de vazar para testes/código (#76).
- Antes só baniam spec IDs do "nome do teste"; o modelo os estacionava no título do `describe()`/suite.
- Bloqueio ampliado para todo identificador de teste: `describe/it`, JUnit `@Nested`/`@DisplayName`/`@Test`, .NET `[Fact]`/`[Theory]`, Go `t.Run`/`func TestXxx`.
- `MOB-XXXX` hardcoded generalizado para qualquer prefixo de time do Linear (`<TEAM>-NNN`).
- Placeholders de URL de report nos templates tornados neutros.

## 2.7.3 — 2026-06-01

### Fixes
- `homolog` transiciona issues para Done no Linear de forma confiável (#75).
- Estado "In Progress" passa a ser resolvido por nome, igual ao estado de conclusão.
- Inclui detecção automática dos nomes de workflow-state.

### Docs
- Campos de config `In Progress Status` / `Done Status` documentados e revertidos no mesmo PR.

## 2.7.2 — 2026-05-31

### Refactors
- Planejamento test-aware + split do `develop` em orquestrador + leaf (#74).
- Novo skill `ship:plan` (Sonnet) faz UMA interpretação dos cenários `@SC-XX` e emite `plan.md`.
- `plan.md` vira fonte única de verdade (mapa de módulos + contrato de testes) para develop e test, reduzindo drift.
- Planner fica no "o quê/onde" (fronteiras de módulo, arquivos disjuntos, slots cenário→teste) e nunca prescreve assinaturas.
- `ship:develop` vira orquestrador determinístico em Haiku (sem Edit/Write): lê o `plan.md`, faz fan-out de um leaf por módulo, integra e roda typecheck.
- Implementação migra para o leaf renomeado `ship-develop-implement` (Sonnet).
- Regra de zero-comentários/zero-spec-IDs passa a viver num único lugar.
- Orquestrador de testes passa a ler o Test Contract do `plan.md`.

## 2.7.1 — 2026-05-31

### Refactors
- Proibidos comentários e marcadores de spec-ID em código/testes gerados (#73).
- Código do `/ship:develop` vazava spec IDs (REQ/AC/SC/MOB) via `// IMPL-SC-XX` e permitia JSDoc/comentários "por quê".
- Testes eram nomeados referenciando SC-XX e emitiam `// TEST-SC-XX` (ex.: `it("AC-23: should import Edges type")`).
- Agora o código é renomeado para carregar significado em vez de anotado.
- Testes nomeados por comportamento observável, sem marcadores e sem spec IDs.

## 2.7.0 — 2026-05-28

### Docs
- Comportamento de auto-update documentado no README (EN + pt-BR) (#72).

## 2.6.0 — 2026-05-28

### Features
- Workflow `version-guard` no CI (#71).
- Enforce de semver no `plugin.json` a cada PR, impedindo bumps inválidos ou fora de ordem.

## 2.5.6 — 2026-05-28

### Internals
- Metadata do manifesto enriquecida para auto-update (#70).
- Campos `repository`, `homepage`, `license` e `keywords` em `plugin.json` e `marketplace.json`.
- Valores consistentes entre os arquivos para a descoberta de auto-update do Claude Code.

## 2.5.5 — 2026-05-28

### Docs
- README reescrito com estrutura narrativa problem-first (#69).

## 2.5.4 — 2026-05-28

### Refactors
- Removido o banner de auto-attestation pouco confiável (#68).
- A self-attestation em runtime (2.5.3) não era um sinal de confiança garantido.

## 2.5.3 — 2026-05-28

### Features
- Sinal de confiança de model-routing em runtime (#67).
- Todo skill/agente emite `🔧 <name> running on: <exact-model-id>` antes de qualquer tool call.
- Lê o ID real do modelo do contexto, nunca um alias de tier.
- Complementa o `dispatch-log.md` (que registra só a intenção do orquestrador).

### Internals
- `src/agents/` vira fonte única de verdade no build.
- Antes só 3 dos 13 agentes viviam em `src/agents/`; os outros 10 eram espelhados manualmente, causando drift silencioso.

## 2.5.2 — 2026-05-28

### Fixes
- `subagent_type` com namespace de plugin para agentes `ship-*` (#66).
- Corrige a resolução dos agentes nomeados quando o plugin está instalado.

## 2.5.1 — 2026-05-27

### Fixes
- `review` escreve findings no scratch dir em modo pipeline Linear (#65).
- Evita perda de findings quando o pipeline roda integrado ao Linear.

## 2.5.0 — 2026-05-25

### Fixes
- Restaurado o prefixo `ship:` nos nomes dos skills (#64).
- Autocomplete de slash commands volta a funcionar.

## 2.4.0 — 2026-05-25

### Features
- Dispatch log por fase (#63).
- Novo `dispatch-log.md` (`Phase | Tool | Name | Model | Timestamp`) criado no init do pipeline.
- Orquestrador emite `▶ Fase: … | tool=… | name=… | model=…` no terminal e anexa a mesma linha antes de cada dispatch.
- Re-runs anexam novas linhas; fases puladas ganham linha `tool=- name=skipped` para manter o rastro completo.

### Refactors
- Removida a "Model Summary" quebrada do `homolog`.
- Seção `## Modelos Utilizados` (tabela + custo via `/cost`) substituída por um Execution Trace.

## 2.3.1 — 2026-05-25

### Refactors
- Pattern Skill-wrapper + Agent nomeado consolidado (MOB-1554..MOB-1568) (#62).
- Cada fase vira um skill-wrapper fino que despacha um agente nomeado dedicado (`ship-<name>`).
- Frontmatter padronizado (name, description, tools, model), separando control-flow de raciocínio.

## 2.3.0 — 2026-05-24

### Refactors
- `ship:security` migrado para o pattern M4 de agente nomeado — MOB-1556 (#49).
- POC do Skill-wrapper + Agente Nomeado.
- ADR `001-agent-pattern` documenta convenção de nomes, frontmatter padrão e espelhamento `src/` ↔ `plugins/ship/`.

## 2.2.0 — 2026-05-24

### Features
- Script `check-model-declared.sh` + docs do `ship:run` (#46).
- Model Summary Section do `homolog`: tabela fase × modelo, custo real via `/cost` com fallback.
- `audit:run` fixado em Haiku.

## 2.1.0 — 2026-05-24

### Features
- Banner de sessão no `ship:run` (#43).
- Exibe o tier do modelo da sessão vs. os modelos das fases, com indicador de override quando os tiers divergem.
- Implementação determinística adequada a Haiku, emitida antes do primeiro log `▶ Fase:`.

## 2.0.4 — 2026-05-24

### Fixes
- Confirmação explícita do usuário antes do `/ship:pr` (#42).
- O pipeline não dispara mais a criação de PR sem aprovação.

## 2.0.3 — 2026-05-24

### Fixes
- `ship:run` respeita `security` desabilitado em diff menor (#41).
- Logging de fase adicionado.

## 2.0.2 — 2026-05-24

### Fixes
- `audit:run` invoca skills com `context: fork` em vez do wrapper Agent (#40).
- Guard de CI passa a barrar wrapping de `Skill(ship:X)` pela Agent tool.

## 2.0.1 — 2026-05-24

### Fixes
- `ship:run` invoca phase skills com `context: fork` em vez do wrapper Agent (#39).
- Corrige o caminho de invocação das fases.

## 2.0.0 — 2026-05-24

### ⚠️  Breaking changes
- Distribuição agora é plugin puro (sem `install.sh`).
- Skills distribuídas com patterns já inlinados em build-time.
- Instalação via `claude plugin install ship` — sem script manual.
- Removidos: `install.sh`, `update.sh`, skill `/ship:update`.
- Removida: pasta `ship/patterns/` no projeto consumidor (pode ser deletada à vontade).

### Como migrar (usuários antigos)
- Desinstalar o Ship antigo: apagar `.claude/commands/ship/` e `ship/patterns/`.
- Instalar via marketplace: `claude plugin install ship`.
- Continuar usando os mesmos slash commands (`/ship:spec`, `/ship:run`, etc.) — comportamento idêntico.

### Internals
- Source em `src/` na raiz do repo (skills, patterns, shared templates).
- Build output em `plugins/ship/skills/` — committed, descoberto via default discovery (sem campo `skills` no manifest).
- Build script `plugins/ship/scripts/build.js` (inliner de `@ship/...`): resolve referências recursivamente (MAX_DEPTH=10, cache de leitura), falha com exit 1 em referência quebrada e preserva o frontmatter YAML.
- CI valida que `plugins/ship/skills/` está em sync com `src/` em toda PR/tag.

## 1.11.0 — 2026-05-24

### Features
- Pattern orchestrator-on-Haiku para `ship:run` e `ship:init` (#31).
- Orquestradores de puro template/control-flow rodam em Haiku.
- Cada Agent que exige raciocínio recebe `model: "sonnet"` explícito (develop, test, perf/security/review, fix, analyze).
- Ordenação multi-task reescrita para usar só sinais determinísticos (ordem de milestone no Linear, depois data de criação).

## 1.10.1 — 2026-05-24

### Docs
- Reforçada a regra de não emitir comentários desnecessários no agente de develop (#30).

## 1.10.0 — 2026-05-17

### Docs
- Documentado o suporte a cenários BDD Gherkin adicionado na v1.9.0 (#29).

## 1.9.0 — 2026-05-17

### Features
- Captura de cenários BDD Gherkin no momento da spec, por todo o pipeline (#28).
- `spec`: enumera cenários Gherkin por critério de aceite, com IDs `AC-XX` explícitos.
- Cenários `@SC-XX` globais tagueados com `@AC-YY` e uma camada de teste dona, mais Scenario Index na Proposal e checagem de cross-reference.
- Trabalho de cenário feito uma vez na spec em vez de re-derivado na fase de teste.
- `init`: novo knob `## Scenario Depth` (none|light|full, default full), com pergunta interativa e preservação em reconfigure.
- `analyze`: correlação cenário→teste pela camada tagueada e extrator de keywords ciente de Gherkin (não degrada o Jaccard).
- `analyze`: marcadores TEST-SC/IMPL-SC, gap SCENARIO (medium/WARN), tabela Scenarios Status.
- `analyze`: blocos SC incluídos no `spec_hash` — edição só de cenário invalida o cache.

## 1.8.6 — 2026-05-11

### Refactors
- Removido o prefixo de namespace de plugin dos nomes das pastas de skill.

## 1.8.5 — 2026-05-11

### Refactors
- `ship:pr` consome `linear-cache.json` para pular `list_documents` redundante (MOB-1287) (#27).

## 1.8.4 — 2026-05-11

### Performance
- Cache de similaridade Jaccard no `ship:analyze` para evitar recomputação em re-runs (#26).

## 1.8.3 — 2026-05-10

### Refactors
- Centralizada a injeção de `artifact_language` no orquestrador do `ship:run` (#25).

## 1.8.2 — 2026-05-10

### Refactors
- Inlinadas as regras de severity/gate em `perf`, `security` e `review` (MOB-1284) (#24).

## 1.8.1 — 2026-05-10

### Chore
- Desabilitadas as fases de pipeline `test` e `security` na config (#23).

## 1.8.0 — 2026-05-10

### Refactors
- Garante que `ship:run` nunca invoca audits project-wide (MOB-1283) (#22).
- Reforça a separação entre fases de pipeline (diff-scoped) e comandos de audit (project-wide).

## 1.7.0 — 2026-05-10

### Features
- `audit:run` consolida via JSON inline (MOB-1282) (#21).
- Relatório consolidado dos audits a partir de JSON em vez de arquivos intermediários.

## 1.6.0 — 2026-05-10

### Refactors
- `homolog` lê `phase-status.md` antes dos findings markdown (MOB-1281) (#20).

## 1.5.0 — 2026-05-10

### Features
- Classificador de diff trivial no `ship:run` (MOB-1280) (#19).
- Heurística determinística que classifica o diff (trivial/minor/normal/large).
- Seção opcional `Sensitive Paths` no `ship/config.md`.
- Nova Fase 0.7 (classificação); Fase 4 pula agentes de qualidade em diffs triviais ou usa 1 agente combinado em diffs menores.

## 1.4.0 — 2026-05-10

### Refactors
- Inline do slicing de contexto nos sub-agentes paralelos do fan-out (#18).

## 1.3.0 — 2026-05-10

### Features
- Model-routing: força Haiku em skills de fase-template (#17).
- Primeira formalização do roteamento por tier de modelo.

## 1.2.4 — 2026-05-09

### Fixes
- Usa o nome de plugin totalmente qualificado nas instruções de update (#16).

## 1.2.3 — 2026-05-09

### Performance
- Reduzidas chamadas MCP redundantes em `pr`, `homolog` e `run` (#15).

## 1.2.2 — 2026-05-09

### Fixes
- Distribui os arquivos de pattern e os move para dentro de `plugins/ship/` (#14).

## 1.2.1 — 2026-05-09

### Performance
- Heurísticas de eficiência de Read nas fases develop e test (#13).

## 1.2.0 — 2026-05-08

### Internals
- Bootstrap do versionamento automático via Conventional Commits.
- Sem mudança funcional (primeiro bump gerado pelo CI).

## 1.1.0 — 2026-05-08

### Features
- Test Scope (#1–#7): nova seção `## Test Scope` no `ship/config.md` controlando quais camadas (unit/integration/e2e) o `/ship:test` gera.
- Defaults por tipo de projeto e prompt interativo no `/ship:init`.
- Enforce em `ship:test` (filtra agentes) e `ship:analyze` (filtra findings de cobertura pelas camadas habilitadas).
- Novo comando `/ship:audit:tests` — audit project-wide de cobertura de testes.
- `audit:tests` incluído no roteamento universal e no launch paralelo do `audit:run`.

### Fixes
- `ship:update`: migração de config para seções faltantes (#8).
- `ship:update`: suporte a instalação global de plugin e correção dos paths de URL de skill (#9).

### CI
- Auto version bump via Conventional Commits no merge para `main` (#12).

### Docs
- Seção "Updating Ship" no README (EN + pt-BR).
- Documentação dos comandos de Test Scope / audit:tests.

## 1.0.0 — 2026-05-03

### Features
- Release inicial do Ship.
- Framework de pipeline de desenvolvimento como conjunto de slash commands `/ship:*` do Claude Code.
- Pipeline: spec → plan → develop → test → perf → security → review → analyze → homolog → pr.
- Comandos de audit project-wide.
- Artefatos persistentes (Linear ou markdown local) e tracking contínuo.
