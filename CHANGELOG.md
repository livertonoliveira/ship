# Changelog

Histórico reconstruído a partir do versionamento automático (`plugin.json`) e dos commits de cada release. Versões em ordem decrescente.

## 4.1.0 — 2026-07-26

### Features
- **Graph mode implementado** — `/ship:graph` executa o pipeline em paralelo **entre tarefas**.
- Scheduler de work-graph agnóstico de runtime (`src/hooks/graph.sh`): arestas de dependência + conflito de arquivos e um merge node serializado que verifica as tarefas em conjunto.
- Cada nó roda um `/ship:run` completo em workspace isolada, via drivers plugáveis (`manual`/`local`/`orca`) com quatro verbos (`dispatch`/`collect`/`wait`/`ask`); nada muda dentro de uma tarefa.
- Word budget dos skills sobe de 999 para 1500 palavras para acomodar o novo orquestrador.
- Corrige bypass silencioso de Sensitive Paths no `diff-classify.sh`.
- Novo guard de regressão impede o fan-out de testes de apagar cobertura existente.

## 4.0.0 — 2026-07-24

### Docs
- Proposta e plano de build do graph mode para execução paralela de tarefas (#201) — o major marca a chegada do novo modo de execução cross-task.
- Documenta a arquitetura baseada em Orca para rodar tarefas independentes do Ship em paralelo em worktrees, sem tocar no `pipeline.sh`.
- O plano cruza a proposta com o código real (`pipeline.sh`, `build.js`, CI) e corrige seis pontos onde o design quebraria (hook bundling, fronteira de I/O do Linear, defer do homolog, ordem de claim, custo do merge node, binário do Orca ausente), transformando-os em fases, commits e testes concretos.

## 3.0.0 — 2026-07-23

### Changes
- **BREAKING**: fase analyze/drift removida do pipeline (#200). O comando `/ship:analyze` e a fase de análise deixam de existir; análise de cobertura project-wide continua disponível via `/ship:audit:tests`.
- Motivo: em runs reais o correlator Jaccard por keyword produzia quase só falsos positivos em projetos com spec em PT e código em EN — zero drift real detectado, escalações manuais forçadas e, em um run, o fix-loop do gate estourou o cap de 3 iterações perseguindo um artefato de correlação incorrigível.
- Como o `develop` de contexto único implementa o plano/test contract diretamente, drift spec→code→test é raro por construção; a fase só adicionava latência e ruído. Remover a superfície (em vez de adicionar prosa defensiva) segue a Anti-Bloat Rule.
- Deletados o skill analyze, o agente `ship-analyze` e os hooks `analyze-correlate.sh`/`analyze-precheck.sh`; analyze excisado do state machine do `pipeline.sh` (fases, hooks obrigatórios, fan-out, gate, re-run cirúrgico).
- Simplificados `quality-scope.sh`, `rerun-scope.sh`, `findings-gate.sh` e `findings-identity.sh`; patterns, templates, README e CLAUDE.md atualizados; `audit:tests` agora é autocontido.

## 2.77.0 — 2026-07-23

### Features
- Gate estático + fixes no test worker para cortar loops de review (#199).
- Typecheck/lint rodam como gate determinístico logo após o develop e **antes** do fan-out de perf/security/review — nenhum reviewer LLM gasta tokens em código que não compila (`test-exec.sh --static-only` + fix-loop próprio limitado a 2 iterações).
- Fixes agrupados: arquivos de teste saem da denylist do test worker; testes gerados são intent-added (`git add -N`); design doc passa a ser fornecido aos reviewers de perf/security; telemetria de parada de loop (fixpoint / churn-deferred / capped-deferred).

## 2.76.2 — 2026-07-23

### Fixes
- Fix-loop do gate deixa de rodar desenfreado (#198): cap resume-safe (contador não reseta em re-invocação) + guard de identidade por finding (`findings-identity.sh` emite `<phase>|<severity>|<file>|<slug>`), distinguindo finding novo de nit regenerado por reviewer subjetivo.

## 2.76.1 — 2026-07-22

### Fixes
- Falsos positivos de orphan cross-language eliminados: arquivos de teste alterados saem da detecção de orphan (já correlacionados via passes AC/SC→test) (#197).
- Fix-loop do gate ganha fixpoint de convergência: se um ciclo de fix não muda os inputs do gate, os findings vão ao usuário (ask) em vez de re-despachar.

## 2.76.0 — 2026-07-22

### Fixes
- Agente de fix recebe os erros reais quando a suíte falha sem parse estruturado (#196).

## 2.75.0 — 2026-07-22

### Features
- Subcomando `pipeline.sh next`: state machine determinístico que dirige o run inteiro (#195) — deriva o estado do scratch dir a cada chamada, executa todos os passos determinísticos e emite exatamente uma instrução (dispatch/work/ask/stop/done). Ordenação de fases, detecção de silent-write-failure e caps de fix-loop passam a ser propriedade do script, não de prosa.
- Briefs de teste fatiados por SUT.

## 2.74.10 — 2026-07-22

### Fixes
- Build passa a empacotar os siblings transitivos de `$HOOK_DIR` (#194): skill que lazy-referencia um único hook não gera mais instalação quebrada que só falhava no meio do run.

## 2.74.9 — 2026-07-22

### Fixes
- Falha ruidosa em hook de pipeline ausente via preflight `require_hooks` (#193).

## 2.74.8 — 2026-07-22

### Internals
- CI reconhece o wiring transitivo do `evidence-gate.sh` via `pipeline.sh` (#192).

## 2.74.7 — 2026-07-22

### Changes
- Overhead de orquestração reduzido para diffs pequenos (#191): timings de wall-clock por fase (`timings.tsv` + `report-timings`) e sequência pós-develop colapsada em um único subcomando `pipeline.sh post-develop` (menos round-trips do orquestrador).

## 2.74.6 — 2026-07-20

### Internals
- `develop` excluído do guard wrapper-thin do CI (#190) — ele agora é implementador direto, não wrapper.

## 2.74.5 — 2026-07-20

### Changes
- Paralelismo restrito a quality/test/audit; `ship:develop` vira implementador direto (#189) — escreve todos os módulos ele mesmo, em ordem de dependência, num único contexto (Edit/Write, sem leaf workers). Remove o custo de recarga de contexto por worker e o overlap develop/test-generate; agente `ship-develop-implement` deletado.
- `ship:spec` também passa a coletar contexto inline.

## 2.74.4 — 2026-07-20

### Fixes
- Gates do `config.md` aplicados deterministicamente por script, não por prosa de LLM (#188).

## 2.74.3 — 2026-07-20

### Refactors
- Lógica de diff/gate/scope do Ship movida para scripts determinísticos em `hooks/` (#187).

## 2.74.2 — 2026-07-19

### Fixes
- Gate do `ship:run` bloqueia em fases despachadas-mas-incompletas (#186) — sem mais consolidar por cima de worker que não terminou.

## 2.74.1 — 2026-07-19

### Docs
- Proposta SPEC-18 removida agora que está implementada (#185).

## 2.74.0 — 2026-07-19

### Docs
- Categoria de secrets e sweep condicional documentados no hygiene-gate (#184).

## 2.73.0 — 2026-07-19

### Features
- Sweep de hygiene do `ship:test` condicionado ao marcador hygiene-hit (#183) — só roda quando o hook registrou violação.

## 2.72.0 — 2026-07-19

### Features
- Caps de iteração do fix-loop persistem através de compaction de contexto (#182).

## 2.71.2 — 2026-07-19

### Changes
- Latência do pipeline/audit reduzida e wiring de testes endurecido (#181): typecheck e lint rodam concorrentes no `test-exec` (wall-clock = o mais lento dos dois); `audit:run` consolida inline em vez de spawnar agente; novo analisador de session-timing.

## 2.71.1 — 2026-07-18

### Changes
- Forks de subprocess redundantes eliminados em `evidence-gate`/`hygiene-scan` (#180).

## 2.71.0 — 2026-07-18

### Changes
- Forks de shell por registro eliminados no `analyze-correlate` (#179).

## 2.70.0 — 2026-07-18

### Features
- Sweep de hygiene do `develop` condicionado ao marcador `.hygiene-hit` da TASK-001 (#178).

## 2.69.2 — 2026-07-18

### Fixes
- Gate de typecheck/lint determinístico + hygiene scan restrito ao escopo do diff (#177).

## 2.69.1 — 2026-07-18

### Internals
- Suíte de testes do `hygiene-scan.sh` cobrindo ciclo de vida do marker e detecção de secrets (#176).

## 2.69.0 — 2026-07-18

### Fixes
- Sem pedido de confirmação para mover issue do Linear para In Progress (#175).

## 2.68.0 — 2026-07-18

### Features
- Detecção de secrets + marcador de violação no `hygiene-scan.sh` (#174).

## 2.67.0 — 2026-07-18

### Features
- Overlap develop∥test-generate generalizado para o caso sem planner (#173).

## 2.66.0 — 2026-07-18

### Features
- `run-footprint.js`: gate de CI para o instruction footprint de um run (#172).

## 2.65.5 — 2026-07-18

### Docs
- Anti-Bloat Rule registrada em CLAUDE.md e BUDGETS.md (#171).

## 2.65.4 — 2026-07-18

### Docs
- Specs obsoletas podadas do framework-comparison e restantes ranqueadas por prioridade (#170).

## 2.65.3 — 2026-07-18

### Fixes
- `analyze` captura o corpo do REQ + escalação semântica de gray-zone (#169).

## 2.65.2 — 2026-07-18

### Fixes
- Linha de proibição de audit no `run` reescrita para passar no grep guard do CI (#168).

## 2.65.1 — 2026-07-18

### Changes
- Word budget de skill/agent achatado para 999 palavras (exceção do orquestrador: 1200) (#167).

## 2.65.0 — 2026-07-18

### Changes
- test-exec ∥ quality paralelizados com reconciliação cirúrgica (#166).

## 2.64.0 — 2026-07-18

### Features
- `test-exec.sh`: execução determinística da suíte de testes via hook (#165).

## 2.63.2 — 2026-07-18

### Internals
- Guard anti-bookkeeping no CI + testes gateSemantics para o `pipeline.sh gate` (#164).

## 2.63.1 — 2026-07-18

### Refactors
- Seções quality/gate/homolog do `run/SKILL.md` reescritas; budget reduzido para 2000 palavras (#163).

## 2.63.0 — 2026-07-18

### Refactors
- Fases de construção do `run/SKILL.md` consolidadas via `pipeline.sh` (#162).

## 2.62.0 — 2026-07-18

### Features
- Subcomando `gate` no `pipeline.sh` — aritmética determinística de gates (#161).

## 2.61.0 — 2026-07-18

### Features
- Subcomandos `dispatch`/`complete` no `pipeline.sh` (#160).

## 2.60.0 — 2026-07-18

### Internals
- Testes de hooks (`.test.sh`) integrados ao CI com runner dedicado (#159).

## 2.59.0 — 2026-07-18

### Features
- Fachada `pipeline.sh` com subcomando `init` (#158) — início da migração do sequenciamento do run para script.

## 2.58.1 — 2026-07-17

### Docs
- Specs implementadas e design docs obsoletos podados (#157).

## 2.58.0 — 2026-07-17

### Changes
- Engine de correlação determinística no `analyze` + consolidação do setup do pipeline (#156).

## 2.57.0 — 2026-07-17

### Features
- Linha `Status` nos Reports dos workers de build (MOB-2432) (#155).

## 2.56.0 — 2026-07-17

### Fixes
- Todos os skills do Ship fixados em Sonnet; tier Haiku eliminado (#154).

### Features
- `worker-status-gate.sh` determinístico com testes unitários (#153).

## 2.55.0 — 2026-07-17

### Features
- Pattern de enum worker-status com testes unitários (#152).

## 2.54.0 — 2026-07-15

### Internals
- Verificação do wiring do wrapper MOB-2378 e validação de build (#151).

## 2.53.0 — 2026-07-15

### Features
- `analyze`: derivação de gate explícita e orphans cobertos no rendering lazy-load (#150).

## 2.52.0 — 2026-07-15

### Features
- `analyze`: passes semânticos via LLM (AMBIG/SUBSPEC/PRINCIPLE) (#149).

## 2.51.0 — 2026-07-14

### Features
- `analyze`: passes determinísticos de detecção DUP e TERM (#148).

## 2.50.0 — 2026-07-14

### Features
- `analyze`: pass de detecção reversa de orphans (#147).

## 2.49.0 — 2026-07-14

### Features
- `analyze`: cobertura renderizada como percentual inteiro por item e agregada por tier (#146).

## 2.48.0 — 2026-07-14

### Features
- Schema de drift-findings estendido com novas categorias, confiança em % e template de orphans (#145).

## 2.47.0 — 2026-07-13

### Features
- Fase analyze e 6 novas categorias de drift finding registradas no `severity.md` (#144).

## 2.46.0 — 2026-07-12

### Features
- `spec`: passo §3.5 Clarify + gate por marcador + regra de no-leakage (#143).

## 2.45.0 — 2026-07-12

### Features
- Hook de gate `needs-clarification-scan` + testes (#142).

## 2.44.0 — 2026-07-12

### Features
- `init`: seção `## Clarify` no config, pergunta ao usuário e regra de preservação (#141).

## 2.43.1 — 2026-07-12

### Internals
- Teto do word budget do skill `spec` elevado para 4400 palavras (#140).

## 2.43.0 — 2026-07-11

### Docs
- Filosofia e how-to do pressure-testing harness + seção Tier 3 (#139).

## 2.42.0 — 2026-07-11

### Features
- Pressure harness: caso de fixture real + integração com CI (MOB-2313) (#138).

## 2.41.0 — 2026-07-11

### Features
- Pressure harness: orquestrador `pressure-run` com modos record/replay (#137).

## 2.40.0 — 2026-07-11

### Features
- Pressure harness: builder do braço de controle — remove a instrução e reconstrói isolado (#136).

## 2.39.0 — 2026-07-11

### Features
- Pressure harness: rendering de report e semântica de exit code (#135).

## 2.38.0 — 2026-07-09

### Features
- Pressure harness: agregação de pass-rate, variância, delta e veredicto (#134).

## 2.37.0 — 2026-07-09

### Features
- Pressure harness: biblioteca determinística de assertions (MOB-2308) (#133).

## 2.36.0 — 2026-07-09

### Docs
- Diagrama de arquitetura do Ship reconstruído como grafo interativo (#132).

## 2.35.0 — 2026-07-09

### Features
- Pressure harness: loader/validator de cases e enumeração de cassettes (#131).

## 2.34.2 — 2026-07-09

### Docs
- Diagrama interativo de arquitetura do Ship adicionado (#130).

## 2.34.1 — 2026-07-09

### Docs
- Sistema de word-budget documentado no BUDGETS.md (#129).

## 2.34.0 — 2026-07-09

### Internals
- Passo `npm test` adicionado ao job build-drift do CI (MOB-2281) (#128).

## 2.33.0 — 2026-07-08

### Features
- Gate de word-budget para arquivos SKILL.md no build (MOB-2280) (#127).

## 2.32.8 — 2026-07-08

### Refactors
- Poda de no-ops nos agentes de test e develop-implement (#126).

## 2.32.7 — 2026-07-08

### Refactors
- Poda de no-ops em security, audit-tests, review e perf (#125).

## 2.32.6 — 2026-07-08

### Refactors
- Poda de no-ops em ship-audit-{backend,database,security} (#124).

## 2.32.5 — 2026-07-08

### Refactors
- Poda de no-ops em ship-audit-frontend e ship-analyze (#123).

## 2.32.4 — 2026-07-08

### Refactors
- Poda de no-ops e consolidação de boilerplate em 9 skills pequenos (#122).

## 2.32.3 — 2026-07-08

### Refactors
- Poda de no-ops em test, plan, develop e audit:run (#121).

## 2.32.2 — 2026-07-08

### Refactors
- Poda de no-ops em pr, init e homolog (#120).

## 2.32.1 — 2026-07-08

### Refactors
- Poda de no-ops e compressão de leading-words no `ship:spec` (#119).

## 2.32.0 — 2026-07-07

### Refactors
- Poda de no-ops e compressão de leading-words no `ship:run` (#118).

## 2.31.0 — 2026-07-07

### Internals
- Guard de wiring dos status-scripts + registro no CI (MOB-2212) (#117).

## 2.30.0 — 2026-07-07

### Features
- Hook que bloqueia comandos git destrutivos antes de executarem (#116).

## 2.29.0 — 2026-07-07

### Features
- Hooks status-consolidate/evidence-gate/rerun-scope conectados ao orquestrador do `run` (#115).

## 2.28.0 — 2026-07-06

### Features
- `rerun-scope.sh`: escopo determinístico de re-run cirúrgico (#112).
- `evidence-gate.sh`: reporta arquivos-fonte sem teste (#114).
- Script `status-consolidate` + harness de teste (MOB-2208) (#113).

## 2.27.0 — 2026-07-06

### Features
- Gate de validação pós-planner + wiring guard no `ship:run` (#111).

## 2.26.0 — 2026-07-06

### Internals
- Harness de teste do `plan-validate.sh` como guard de regressão (#110).

## 2.25.0 — 2026-07-06

### Features
- `plan-validate.sh`: validador determinístico do `plan.md` (#109).

## 2.24.4 — 2026-07-06

### Internals
- Guard de regressão: lazy-load do orquestrador travado no CI (#108).

## 2.24.3 — 2026-07-06

### Refactors
- `ship:run`: patterns inline convertidos em lazy-load `@@ship/` (#107).

## 2.24.2 — 2026-07-05

### Docs
- Análise comparativa de frameworks e specs de melhoria adicionadas (#106).

## 2.24.1 — 2026-07-05

### Fixes
- `ship:run`: eliminada a race de phase-status e as lacunas de dispatch em background (#105).

## 2.24.0 — 2026-07-05

### Fixes
- `ship:run`: proteção contra busca filesystem-wide quando a resolução de path falha (#104).

## 2.23.0 — 2026-07-05

### Features
- `ship:run`: test-generate despachado em paralelo com o develop (#103).

## 2.22.0 — 2026-07-05

### Features
- `ship:run`: analyze movido para o fan-out de qualidade da Fase 4 com gate único agregado (#102).

## 2.21.0 — 2026-07-04

### Features
- `ship:test`: dispatch de geração e execução de testes baseado em modo (#101).

## 2.20.0 — 2026-07-04

### Features
- `ship:run`: planner pulado deterministicamente para tarefas de módulo único (#100).

## 2.19.0 — 2026-07-04

### Features
- `ship:plan`: validação do file map da issue e registro de divergências (#99).

## 2.18.0 — 2026-07-04

### Features
- `ship:run`: `spec.md` fatiado por tarefa no scratch dir (#98).

## 2.17.0 — 2026-07-04

### Features
- `ship:spec`: seção `## Files` com referências de âncora por tarefa (#97).

## 2.16.0 — 2026-07-04

### Features
- `sc-crossref.sh`: validação de referência cruzada SC↔AC (#96).

## 2.15.0 — 2026-07-04

### Features
- `capture-diff.sh` com assertion de unified-diff (#95).

## 2.14.0 — 2026-07-04

### Features
- `diff-classify.sh`: classificador determinístico de diff (#94).

## 2.13.0 — 2026-07-04

### Features
- `snapshot-files.sh` substitui os blocos inline de content-snapshot (#93).

## 2.12.8 — 2026-07-04

### Refactors
- `ship:run`: passo de session banner removido (#92).

## 2.12.7 — 2026-07-04

### Refactors
- `hygiene-scan.sh` empacotado nos skills via referência lazy `CLAUDE_SKILL_DIR` (#91).

## 2.12.6 — 2026-06-28

### Fixes
- Hygiene gate interpretado por LLM substituído por scan Bash explícito (#90).

## 2.12.5 — 2026-06-16

### Fixes
- Gate de review determinístico + orquestrador sem poder de override sobre findings (#89).

## 2.12.4 — 2026-06-16

### Changes
- Corte no footprint de tokens em runtime — run −61%, todos os skills −33% (#88): orquestrador grava `spec.md`/`design.md` uma vez no scratch dir e passa só o path; agentes de fase leem os arquivos, sem re-inlining do diff/spec/design em cada dispatch.

## 2.12.3 — 2026-06-16

### Fixes
- Captura de diff confiável (merge-base da working tree em vez do range three-dot vazio), cobertura por outcome de AC no planner e `ship:run` em Sonnet (#87).

## 2.12.2 — 2026-06-05

### Fixes
- Issue do Linear marcada como Done de forma confiável: transição de estado verificada e resolvida por ID (#86).

## 2.12.1 — 2026-06-05

### Refactors
- Contexto de runtime do Ship enxugado: migração thin-wrapper + build anchor-aware (#85); lint `check-wrapper-is-thin` reconhece `subagent_type` com prefixo de plugin.

## 2.12.0 — 2026-06-05

### Features
- Release que publica a hygiene zero-comentário/zero-spec-ID endurecida (#84) — de-identificação de contexto + hook PostToolUse determinístico, descritos em detalhe na entrada 2.11.0 abaixo (o merge ocorreu antes do bump de versão).

## 2.11.0 — 2026-06-04

### Changes
- Orquestradores `ship:develop` e `ship:test` movidos de **Haiku → Sonnet**. Eles não são dispatchers puramente determinísticos: fazem slicing/de-identificação de contexto, ordenação de dependências e precisam despachar de forma confiável (não narrar). Pela Boundary rule do `model-routing.md`, isso os mantém no tier de raciocínio. Não é fix do vazamento de spec ID (o hook já garante isso) — é robustez geral do orquestrador. `model-routing.md`, tabela e `run/SKILL.md` atualizados.

### Features
- **Prevenção por construção (defesa primária)**: os orquestradores `ship:develop`/`ship:test` agora **de-identificam** o contexto antes de injetar nos workers — removem os tags/IDs (`@SC-XX`, `@AC-YY`, `REQ-/AC-/SC-/IMPL-`, chave Linear) das `## Scenarios`/`## Test Contract`/`## Module`, mantendo só o conteúdo comportamental. O worker não ecoa um ID que nunca recebeu. Novo pattern `deidentify-context.md`; workers iteram "scenarios" em vez de `@SC-XX`. Traceability não é afetada — o `ship:analyze` correlaciona por keyword (Jaccard), não por marcador no código (`ship-analyze.md:89`).
- Hygiene gate agora é **determinístico de verdade**: hook `PostToolUse` (`hooks/hygiene-scan.sh`) dispara em todo `Write`/`Edit`, escaneia o arquivo recém-escrito e, ao achar violação, sai com código 2 — o Claude Code bloqueia e devolve os `file:line` ao modelo, que faz o rename/remoção (correção semântica que um script não faz com segurança).
- Antes, o "gate determinístico" (#83) era só um passo de SKILL executado pelo orquestrador Haiku — podia ser narrado como PASS sem nunca rodar o grep. Era a causa de `AC-`/`SC-` vazarem para nomes de testes mesmo na versão mais recente.
- Escopo por regra: **spec IDs** (`REQ-/AC-/SC-/IMPL-/TEST-<n>` + chave Linear do branch) são bloqueados em qualquer `Write`; **comentários** só dentro de um run ativo do Ship (marcador `.context/ship-run/`), para não policiar código escrito à mão pelo usuário.
- Passos de hygiene em `ship:develop`/`ship:test` rebaixados a varredura final (cinto-e-suspensório) atrás do hook.
- Sweep retroativo: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/hygiene-scan.sh" --all` lista violações já gravadas em runs anteriores (não corrigidas pelo hook).
- `build.js` agora copia `src/hooks/` → `plugins/ship/hooks/`.

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
