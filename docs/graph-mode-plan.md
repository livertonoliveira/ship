# Ship Graph Mode — plano de construção (v1)

Status: plano. Nada implementado.
Base: `docs/graph-mode-proposal.md` — a arquitetura daquele documento continua válida.
Este documento acrescenta o que foi encontrado ao cruzar a proposta com o código real
(`src/hooks/pipeline.sh`, `plugins/ship/scripts/build.js`, `.github/workflows/ci.yml`,
`scripts/run-hook-tests.sh`) e converte tudo em fases, commits e testes.

---

## 1. Correções de rota

Seis pontos em que a proposta não bate com o código atual. Três deles mudam o plano.

### 1.1 `src/hooks/drivers/` seria descartado pelo build — sem erro

`buildHooks()` (`plugins/ship/scripts/build.js:281-282`) e `bundleHookSiblings()`
(`build.js:159-160`) fazem `readdirSync` **não-recursivo**, com `if (!entry.isFile()) continue`.
Um subdiretório `src/hooks/drivers/` nunca seria copiado para `plugins/ship/hooks/`, e o
build passaria verde — a instalação só quebraria em runtime, dentro de uma worktree.

**Decisão:** nomes planos, sem subdiretório.

```
src/hooks/driver-orca.sh
src/hooks/driver-local.sh
src/hooks/driver-manual.sh
```

Zero mudança em `build.js`, e `bundleHookSiblings()` já os carrega junto com os demais
hooks para qualquer skill que faça lazy-bundle de `hooks/*.sh`.

### 1.2 `graph.sh` não consegue ler o Linear

A proposta (§3.2) diz que `graph.sh init` constrói o `graph.json` "do `tasks.md` ou das
issues do Linear". `graph.sh` é bash; MCP é ferramenta do LLM. O modo Linear é impossível
como especificado.

**Decisão:** inverter a responsabilidade. O skill faz a I/O, o script faz a lógica.

```
/ship:graph  →  (modo linear)  MCP list_issues + get_issue     →  nodes.json
             →  (modo local)   parse de tasks.md                →  nodes.json
                                                                     │
                                            graph.sh init --from nodes.json
```

É exatamente o padrão que `cmd_next` já usa em `pipeline.sh:960-970` ("Stage the task
context yourself — no sub-agent"). Mantém `graph.sh` puro, determinístico e testável em
CI sem Linear nem rede.

`nodes.json` (contrato mínimo, produzido pelo skill):

```json
[
  { "id": "TASK-002", "repo": "api", "title": "...", "deps": ["TASK-001"],
    "files": ["src/api/routes.ts"] }
]
```

### 1.3 O homolog defer precisa de mais que um `if`

A proposta (§3.6) estima "~5 linhas, um `if` no estado `homolog`". O bloco real
(`pipeline.sh:1421-1432`) **dispara o skill `ship:homolog`**, e é o skill que escreve o
relatório. Um `if` que só pula o bloco faz o grafo não acumular nada para apresentar em
lote — o objetivo da §3.6 morre em silêncio.

**Decisão:** em `defer`, gerar o relatório deterministicamente, sem LLM.

```
homolog-mode.txt == defer
        │
        ├─ monta homolog-report.md de:
        │     cmd_rows            (índice canônico de gate por fase)
        │     cmd_report_timings  (wall-clock por fase)
        │     phase-status.md     (findings consolidados)
        ├─ printf 'deferred\n' > homolog-approved.txt
        └─ segue para o bloco done
```

Tudo já existe (`pipeline.sh:405` `cmd_rows`, `pipeline.sh:336` `cmd_report_timings`).
São ~12 linhas de bash, **zero LLM e zero prosa nova em SKILL/agent** — mais aderente à
Anti-Bloat Rule do que a versão original da proposta.

### 1.4 `graph.sh claim` não pode pré-escrever o marcador

`.context/ship-run/<task>/` é criado por `pipeline.sh init` **dentro** da worktree, que só
existe depois do `dispatch`. Escrever `homolog-mode.txt` no `claim` (proposta §3.6) exige
uma ordem específica:

```
driver dispatch <task>
  → driver collect <task>            # resolve o path da worktree
  → mkdir -p <wt>/.context/ship-run/<task>
  → printf 'defer\n' > <wt>/.context/ship-run/<task>/homolog-mode.txt
  → graph.sh claim <task> --worktree <wt> --branch <b>
```

Nota adicional: `.context/ship-graph/` precisa entrar no `.gitignore` (o `.gitignore`
atual só cobre `.context/ship-run/`).

### 1.5 O merge node é mais barato do que a proposta sugere

`test-exec.sh` só lê `<scratch>/stack.md` (linhas 24-25, 44, 54) — `Test Framework`,
`Package Manager`, `Typecheck`, `Lint`. O scratch sintético do merge node é `mkdir` +
copiar `stack.md`. Sem `generated-tests.md` no scratch, `collect_test_files`
(`test-exec.sh:297`) não restringe o escopo e a suíte inteira roda — que é precisamente o
que o merge node quer.

Isso vira um **teste** (`graph-merge.test.sh` confirma o fallback), não um risco de design.

### 1.6 `orca` não está instalado

`command -v orca` → não encontrado nesta máquina. A Fase 0 é genuinamente bloqueante e
não pode começar antes disso ser resolvido.

---

## 2. Fases

### Fase 0 — Validar o Orca na mão

Bloqueante. Sem código. Quatro provas, nessa ordem:

| # | Prova | Por que importa |
|---|---|---|
| 1 | `orca worktree create --agent claude --setup run --prompt "/ship:run TASK-X" --json` retorna handle | é o verbo `dispatch` |
| 2 | `orca orchestration check --wait --types worker_done` dispara ao fim do `/ship:run` | é o verbo `wait`; sem isso o loop do orquestrador vira polling |
| 3 | `orca worktree show --worktree <h> --json` devolve path **acessível localmente** | **crítico** — sem path local, `git -C <wt> diff --name-only` não roda e a aresta de conflito por footprint real (§3.4 da proposta) não existe |
| 4 | `orchestration gate-create` resolve pelo mobile | é o verbo `ask` e o homolog em lote |

Saída: `docs/graph-mode-orca-findings.md`.
**Se a prova 3 falhar**, a §3.4 precisa de replanejamento (fallback: footprint declarado
apenas, com aresta de conflito conservadora) antes de qualquer linha de código.

---

### Fase 1 — `## Deps` no spec

Independente do Orca. Entrega valor sozinha: o grafo fica visível na UI do Linear.

| Commit | Conteúdo |
|---|---|
| `feat(spec): emit structured ## Deps block in task issues` | `src/skills/spec/SKILL.md:63` — trocar `Notes (deps)` por bloco `## Deps`; modo Linear cria também a relação nativa **blocked by** |
| `test(hooks): deps block parsing from tasks.md` | parse sobre fixture; garante formato estável antes de existir consumidor |

Custo: ~3 linhas de SKILL. Teto de palavras do `spec` (999, `budgets.js`) não é ameaçado.

---

### Fase 2 — `graph.sh` + `driver=manual`

O miolo. Entrega valor sozinha: frontier consultável, dá para coordenar N workspaces à
mão sem se perder.

| Commit | Conteúdo |
|---|---|
| `feat(hooks): graph.sh init/status — build work graph from nodes.json` | schema da §3.1 da proposta; `--from nodes.json` (ver §1.2 acima) |
| `feat(hooks): graph.sh next — frontier protocol` | espelha `next_emit` (`pipeline.sh:872`); estados `frontier\|wait\|merge\|merge-fix\|ask\|done`; idempotente |
| `feat(hooks): graph.sh claim/land/complete/fail` | transições `pending → ready → in_flight → landed → merging → done` |
| `feat(hooks): graph.sh conflicts — declared vs real footprint` | §3.4; footprint real sobrescreve o declarado; desempate por menor ID; `blocked_by_conflict` (não `blocked`) |
| `feat(hooks): driver-manual.sh` | 4 verbos; `dispatch` e `wait` apenas imprimem a frontier |
| `feat(skills): /ship:graph orchestrator skill` | wrapper fino, mesmo padrão do `run`; teto 999 palavras |
| `test(hooks): graph-next.test.sh` | frontier, deps, cap de in-flight, deadlock |
| `test(hooks): graph-conflicts.test.sh` | declarado vs real, desempate determinístico |
| `chore(ci): check-graph-driver-isolation.sh` | falha se `graph.sh` citar um runtime |
| `chore: gitignore .context/ship-graph/` | ver §1.4 |

**Wiring de CI:**
- Testes `src/hooks/tests/*.test.sh` são auto-descobertos por `scripts/run-hook-tests.sh` — nada a fazer.
- O guard **exige um step novo** no job `grep-guard` de `.github/workflows/ci.yml` (não é auto-descoberto).
- `graph.sh` deve entrar em `REQUIRED_HOOKS` (`pipeline.sh:23`)? **Não** — a dependência é ao contrário: `graph.sh` chama `pipeline.sh`, nunca o inverso.

---

### Fase 3 — Paralelismo automático

| Commit | Conteúdo |
|---|---|
| `feat(hooks): pipeline.sh honors homolog-mode=defer` | `pipeline.sh:1421`; relatório determinístico, sem dispatch do skill (§1.3) |
| `test(hooks): homolog defer emits done, not ask` | regressão dura — é o ponto que decide se o ganho é real |
| `feat(hooks): graph.sh merge node` | scratch sintético + `test-exec.sh`; serializado, um merge por vez |
| `feat(hooks): graph.sh iter merge-fix --max 2` | reusa `cmd_iter` (`pipeline.sh:220`); contador persistido, nunca reseta em resume |
| `feat(hooks): driver-orca.sh` | 4 verbos conforme validado na Fase 0 |
| `feat(hooks): driver-local.sh` | `git worktree add` + Agent `isolation: worktree` |
| `test(hooks): graph-merge.test.sh` | merge verde/vermelho, cap do fix-loop, fallback de suíte completa (§1.5) |
| `docs(run): point to /ship:graph for cross-task parallelism` | 1 linha em `src/skills/run/SKILL.md` |

---

### Fase 4 — Multi-repo

Só depois que a Fase 3 rodar em produção por pelo menos uma feature inteira. O campo
`repo` já existe no schema desde a Fase 2 — a Fase 4 é ativação, não redesign.

---

## 3. Decisões pendentes

### 3.1 `max_in_flight` default

A proposta usa `3`. Cada worktree roda um `/ship:run` completo (develop sequencial +
fan-out de verify com até 3 quality agents + N test layers). Três em voo chegam a ~12
agentes simultâneos.

**Recomendação:** default `2`, subir só com evidência de que a máquina aguenta.

### 3.2 Fase 2 tem valor isolado?

Se não houver intenção real de coordenar worktrees à mão, `driver=manual` vira ~2 dias de
trabalho descartável, e faria sentido fundir Fases 2 e 3.

**Recomendação:** manter separado. `driver=manual` é o que torna `graph.sh` testável em CI
sem Orca instalado — sem ele, `graph-next.test.sh` e `graph-conflicts.test.sh` não têm como
rodar no GitHub Actions.

---

## 4. Superfície de arquivos (revisada)

| Arquivo | Ação | Fase | Nota |
|---|---|---|---|
| `src/skills/spec/SKILL.md` | editar (~3 linhas) | 1 | `## Deps` + blocked-by |
| `src/hooks/graph.sh` | **novo** | 2 | não pode citar `orca` |
| `src/hooks/driver-manual.sh` | **novo** | 2 | plano, não em subdiretório (§1.1) |
| `src/hooks/driver-orca.sh` | **novo** | 3 | idem |
| `src/hooks/driver-local.sh` | **novo** | 3 | idem |
| `src/skills/graph/SKILL.md` | **novo** | 2 | wrapper fino, ≤999 palavras |
| `src/hooks/pipeline.sh` | editar (~12 linhas) | 3 | `homolog-mode=defer` (§1.3) |
| `src/skills/run/SKILL.md` | editar (1 linha) | 3 | aponta `/ship:graph` |
| `src/hooks/tests/graph-next.test.sh` | **novo** | 2 | auto-descoberto |
| `src/hooks/tests/graph-conflicts.test.sh` | **novo** | 2 | auto-descoberto |
| `src/hooks/tests/graph-merge.test.sh` | **novo** | 3 | auto-descoberto |
| `scripts/check-graph-driver-isolation.sh` | **novo** | 2 | **+ step em `ci.yml`** |
| `.gitignore` | editar (1 linha) | 2 | `.context/ship-graph/` |
| `plugins/ship/scripts/build.js` | **sem mudança** | — | graças à §1.1 |
| `plugins/ship/scripts/budgets.js` | **sem mudança** | — | `graph` usa `DEFAULT_BUDGET` |
| `plugins/ship/scripts/run-footprint.js` | **sem mudança** | — | `/ship:graph` não é parte do run típico |
| `src/agents/*` | **sem mudança** | — | já são o org graph estável |

---

## 5. O que este plano NÃO muda

Gates de severidade, fix-loop com cap 3 + ledger de identidade (que nunca reseta em
resume), `develop` como implementador inline sequencial, política de audits fora do
pipeline, tetos de palavras. O paralelismo introduzido é **entre tasks**, com isolamento
por worktree e aresta de conflito.
