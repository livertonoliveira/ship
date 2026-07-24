# Ship Graph Mode — proposta de implementação (v1)

Status: proposta. Nada implementado.
Objetivo: executar em paralelo as tasks independentes de uma feature, com o Orca como runtime de worktrees, sem tocar no `pipeline.sh`.

---

## 1. Princípio

Cada nó do grafo é o loop que já existe (`pipeline.sh next`). O grafo só decide **o que pode rodar agora**. Toda a lógica nova vive em hooks determinísticos — nenhuma prosa nova de decisão em SKILL/agent (Anti-Bloat Rule).

```
┌── SHIP (puro, sem dependência de ferramenta) ────────────────────┐
│  graph.sh   — deps · conflito de footprint · merge node · gates  │
└───────────────────────────┬──────────────────────────────────────┘
                            │ 4 verbos do driver
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
   driver=local        driver=orca         driver=manual
   git worktree add    orca worktree /     imprime a frontier
   + Agent isolation   orchestration       (você toca na mão)
```

`graph.sh` nunca menciona `orca`. Guard de CI garante isso.

---

## 2. Fase 1 — arestas estruturadas no `/ship:spec`

O template §6 já produz `## Files` e `Notes (deps)`. A mudança é torná-los parseáveis.

**Antes** (task issue):
```markdown
## Files
create src/db/schema.ts — tabela de pedidos
modify src/api/routes.ts — registrar rota

Notes: depende da TASK-001
```

**Depois** (só o bloco `Notes` vira estruturado; `## Files` já serve como footprint):
```markdown
## Files
create src/db/schema.ts — tabela de pedidos
modify src/api/routes.ts — registrar rota

## Deps
TASK-001
```

- Modo Linear: `## Deps` também vira relação nativa **blocked by** na issue (o grafo aparece de graça na UI do Linear e vira o barramento de estado cross-repo).
- Modo local: parseado de `ship/changes/<feature>/tasks.md`.
- Multi-repo: label `repo:<nome>` na issue.

Custo: ~3 linhas no `src/skills/spec/SKILL.md`. Sem executor ainda — mas o grafo passa a existir.

---

## 3. Fase 2 — `graph.sh` (o work graph)

### 3.1 Estado: `.context/ship-graph/<feature>/graph.json`

```json
{
  "version": 1,
  "feature": "checkout-v2",
  "mode": "linear",
  "driver": "orca",
  "base_branch": "main",
  "max_in_flight": 3,
  "nodes": [
    {
      "id": "TASK-002",
      "repo": "api",
      "title": "Endpoint de checkout",
      "deps": ["TASK-001"],
      "files": ["src/api/routes.ts", "src/api/checkout.ts"],
      "status": "pending",
      "worktree": null,
      "branch": null,
      "attempts": 0,
      "blocked_by_conflict": null
    }
  ],
  "integration": { "last_merged": null, "status": "green" }
}
```

`status`: `pending → ready → in_flight → landed → merging → done` · terminais `failed`, `blocked`.

### 3.2 Subcomandos

| Comando | Efeito |
|---|---|
| `graph.sh init --feature <f> [--driver orca] [--max-in-flight N]` | Constrói `graph.json` do `tasks.md` ou das issues do Linear |
| `graph.sh next [--json]` | Emite a próxima ação (protocolo abaixo) — idempotente |
| `graph.sh claim <task> --worktree <path> --branch <b>` | `ready → in_flight` |
| `graph.sh land <task>` | `in_flight → landed` (pipeline da task terminou verde) |
| `graph.sh complete <task>` | `merging → done`, libera dependentes |
| `graph.sh fail <task> --reason <r>` | `→ failed`, congela admissão de novos nós |
| `graph.sh conflicts` | Recalcula arestas de conflito com o footprint **real** das worktrees em voo |
| `graph.sh status [--json]` | Relatório do grafo |
| `graph.sh iter merge-fix --max 2` | Contador persistido do fix-loop de integração (mesmo padrão de `cmd_iter`) |

### 3.3 Protocolo do `next` — espelha `pipeline.sh next_emit`

```
state=frontier|wait|merge|merge-fix|ask|done
action=dispatch|wait|work|ask|done
inflight=2
frontier=TASK-002 TASK-003
log=.context/ship-graph/checkout-v2/graph-log.md
instruction:
- <linhas literais que o orquestrador executa>
```

### 3.4 As duas arestas

**Dependência** — vem do `## Deps`. Imutável durante a run.

**Conflito** — calculada, e é o que substitui o "nunca em paralelo" atual:

```
A e B conflitam  ⇔  files(A) ∩ files(B) ≠ ∅
                     (match por caminho exato ou prefixo de diretório)
```

- Antes do dispatch: usa o `## Files` declarado.
- Com nó em voo: `git -C <worktree> diff --name-only <base>...HEAD` **sobrescreve** o declarado — se o `develop` tocou mais do que a spec previa, o grafo segura a task vizinha. É a aresta que "aparece por evidência", sem LLM roteando.
- Desempate determinístico: menor ID pega o slot; o outro fica `pending` com `blocked_by_conflict` preenchido (não `blocked` — não é erro).

### 3.5 Merge node (o verificador que não existe hoje)

Duas tasks verdes isoladamente podem quebrar juntas. Por isso `landed ≠ done`:

```
TASK-002 landed ──┐
                  ├─▶ merge --no-ff na base ─▶ test-exec.sh --static-only ─▶ suite completa
TASK-003 landed ──┘        │verde                                                │vermelho
                           ▼                                                     ▼
                    graph.sh complete                              graph.sh iter merge-fix --max 2
                    (libera TASK-004)                              estourou o cap → action=ask
```

Merge é **serializado** (um por vez) e reusa `test-exec.sh` — nada de mecânica nova.

### 3.6 Homolog federado (o ponto crítico)

Hoje o `homolog` é parada obrigatória. Com 3 tasks em voo, viram 3 aprovações assíncronas — se travar aqui, você volta a ser babá e o objetivo morre.

Solução sem prosa nova: `graph.sh claim` escreve `homolog-mode.txt=defer` no scratch da task. O estado `homolog` do `pipeline.sh` lê esse marcador; em `defer`, grava `homolog-report.md`, marca aprovado e emite `done` em vez de `ask`. O grafo acumula os relatórios e apresenta **em lote** ao final (ou via `gate-create` do Orca, um por task, resolvível pelo mobile).

Único toque no `pipeline.sh`: um `if` no estado `homolog`. ~5 linhas.

---

## 4. Fase 3 — driver do Orca

Adapter fino `src/hooks/drivers/orca.sh` com 4 verbos. `graph.sh` chama `driver.sh <verbo>`; trocar de runtime = trocar de arquivo.

| Verbo | `driver=orca` | `driver=local` |
|---|---|---|
| `dispatch <task> <prompt> [<repo>]` | `orca worktree create --repo id:<repo> --name ship/<task> --agent claude --setup run --prompt "/ship:run <task>" --json` | `git worktree add` + Agent `isolation: worktree` |
| `wait` | `orca orchestration check --wait --types worker_done --timeout-ms 900000 --json` | aguarda os Agents retornarem |
| `ask <pergunta>` | `orca orchestration gate-create` | pergunta ao usuário no contexto |
| `collect <task>` | `orca worktree show --worktree <h> --json` → path | path da worktree |

### Loop do orquestrador (`/ship:graph`)

```bash
while :; do
  eval "$(graph.sh next --json)"
  case "$action" in
    dispatch) for t in $frontier; do driver dispatch "$t"; graph.sh claim "$t" ...; done ;;
    wait)     driver wait; graph.sh conflicts ;;
    work)     # merge node: merge + test-exec.sh → complete | iter merge-fix
              ;;
    ask)      driver ask "$question" ;;   # deadlock de deps, merge-fix estourado, homolog em lote
    done)     break ;;
  esac
done
```

### Contrato do worker

O `/ship:run` dentro da worktree termina em `done` e sinaliza `worker_done` (Orca) ou simplesmente retorna (local). Nada dentro da task muda: `develop` continua sequencial, `verify` em fan-out, gates e fix-loop com cap 3 + ledger intactos.

---

## 5. Fase 4 — multi-repo

Nós carregam `repo`. O Orca dispatcha com `--repo id:<repoId>`, então **um cockpit segura worktrees de repos diferentes**.

```
Linear Project ──▶ graph.sh (grafo canônico, cross-repo)
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
      worktree repo:api    worktree repo:web
      /ship:run TASK-B1    /ship:run TASK-F1
              └──── aresta cross-repo ────┘
        (contrato OpenAPI/tipos publicado na issue;
         o estado `context` da F1 carrega esse documento)
```

- Arestas de **conflito** não existem entre repos (footprints disjuntos por definição) — só arestas de dependência.
- Merge node roda **por repo**, na base daquele repo.
- Sem Linear, multi-repo fica fora de escopo: não há barramento de estado honesto entre filesystems.

---

## 6. Superfície de arquivos

| Arquivo | Ação | Notas |
|---|---|---|
| `src/skills/spec/SKILL.md` | editar (~3 linhas) | emitir `## Deps` + relação blocked-by |
| `src/hooks/graph.sh` | **novo** | work graph; não pode citar `orca` |
| `src/hooks/drivers/{orca,local,manual}.sh` | **novo** | 4 verbos cada |
| `src/skills/graph/SKILL.md` | **novo** | wrapper fino, mesmo padrão do `run` (< 999 palavras) |
| `src/hooks/pipeline.sh` | editar (~5 linhas) | marcador `homolog-mode=defer` |
| `src/skills/run/SKILL.md` | editar (1 linha) | aponta `/ship:graph` para paralelismo entre tasks |
| `src/hooks/tests/graph-next.test.sh` | **novo** | frontier, deps, cap de in-flight, deadlock |
| `src/hooks/tests/graph-conflicts.test.sh` | **novo** | declarado vs footprint real, desempate |
| `src/hooks/tests/graph-merge.test.sh` | **novo** | merge verde/vermelho, cap do fix-loop |
| `scripts/check-graph-driver-isolation.sh` | **novo** | falha se `graph.sh` referenciar um runtime |
| `src/agents/*` | **sem mudança** | já são o org graph estável |

---

## 7. Rollout

| Fase | Entrega | Útil sozinha? |
|---|---|---|
| **0** | Validar Orca na mão: `worktree create --agent claude --prompt "/ship:run TASK-X" --json`, `worker_done`, `orca.yaml` preparando a worktree, `gate-create` | — (é o de/para) |
| **1** | `## Deps` no spec + blocked-by no Linear | Sim — grafo visível no Linear |
| **2** | `graph.sh` + `driver=manual` | Sim — frontier consultável, coordena N workspaces sem se perder |
| **3** | `driver=orca` + merge node + homolog defer | Paralelismo automático de verdade |
| **4** | Multi-repo | Um cockpit para o projeto inteiro |

## 8. Riscos

- **Orca em v1.4.x, release quase diário** — a superfície de CLI pode mudar. Mitigado pelo adapter de 4 verbos e por `driver=local` sempre funcionar sem Orca.
- **Homolog federado** é o ponto que decide se o ganho é real — validar na Fase 0.
- **Footprint subdeclarado** no spec — mitigado pelo footprint real sobrescrever o declarado a cada `wait`.
- **Merge node vermelho recorrente** — cap 2 e depois pergunta; nunca loop infinito.

## 9. O que esta proposta NÃO muda

Gates de severidade, fix-loop com cap 3 + ledger de identidade (que nunca reseta em resume), `develop` como implementador inline sequencial, política de audits fora do pipeline, ceilings de palavras. O paralelismo introduzido é **entre tasks**, com isolamento por worktree e aresta de conflito — não é afrouxamento da regra atual, é a condição que a regra exigia.
