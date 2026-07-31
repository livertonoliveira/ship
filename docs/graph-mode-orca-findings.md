# Fase 0 — validação do Orca na mão

Data: 2026-07-24 · Orca CLI: `/usr/local/bin/orca` (206 comandos, `schemaVersion: 1`)
Runtime: `runtimeState: ready`, `graphState: ready`.

Referência: `docs/graph-mode-plan.md` §2 Fase 0. As quatro provas foram executadas
de verdade contra o runtime local, não deduzidas do `--help`.

---

## Resultado

| # | Prova | Resultado |
|---|---|---|
| 1 | `worktree create --agent claude` devolve handle | **passa** (com correção — ver §1) |
| 2 | `orchestration check --wait --types worker_done` dispara | **passa** (com correção — ver §2) |
| 3 | `worktree show --json` devolve path acessível localmente | **passa** — a §3.4 da proposta está de pé |
| 4 | `gate-create` cria/resolve gate | **passa** por CLI; resolução pelo mobile não verificada |

Nenhuma prova falhou. A prova 3 — a única cujo fracasso exigiria replanejar a
§3.4 — passou sem ressalva. **A Fase 3 pode ser construída como planejado.**

---

## 1. Prova 1 — `dispatch`

```
orca worktree create --repo id:<repoId> --name ship-graph-phase0-probe \
  --no-parent --agent claude --setup run --json
```

Devolve `result.worktree.id` (`<repo-id>::<path>`), `result.worktree.path`,
`result.worktree.branch` e `result.startupTerminal.handle`.

**Correção à proposta (§4).** A proposta descreve `dispatch` como uma única
chamada `worktree create --agent claude --prompt "/ship:run TASK-X"`. Isso cria o
worker, mas **não cria provenance de orquestração** — sem `taskId`/`dispatchId` o
worker não tem obrigação de ciclo de vida e a prova 2 nunca dispara (ver §2).

`dispatch` no `driver-orca.sh` é **três** chamadas, nessa ordem:

```
orca orchestration task-create --spec "<prompt>" --task-title "<task>" --json   → task_id
orca worktree create --repo id:<repo> --name <task> --no-parent --agent claude --setup run --json
                                                                               → handle + path + branch
orca orchestration dispatch --task <task_id> --to <handle> --inject --json      → dispatch_id
```

Observações de campo:

- Sem `--agent`, a resposta **não traz `startupTerminal`** — o handle só existe
  quando um agente é lançado.
- `result.agentTerminalHandle` (citado na doc do CLI para runtimes mais novos)
  **não veio** neste runtime; `result.startupTerminal.handle` veio. O driver deve
  ler `agentTerminalHandle` e cair para `startupTerminal.handle`.
- `--no-parent` é obrigatório: sem ele o Orca faz o worktree novo filho do
  worktree chamador, e o base ref herdado seria a branch da feature, não a base.
- `--setup run` força os hooks de setup do repo (`orca.yaml`), como a proposta previa.

## 2. Prova 2 — `wait`

```
orca orchestration check --terminal <coordenador> --wait \
  --types worker_done,escalation --timeout-ms 240000 --json
```

Bloqueou e retornou em ~8 s com:

```json
{ "type": "worker_done",
  "from_handle": "term_a23d…", "to_handle": "term_e649…",
  "payload": "{\"taskId\":\"task_d5b429bf6769\",\"dispatchId\":\"ctx_4f3a34a98595\"}" }
```

**Correção à proposta (§4 e "Contrato do worker").** A proposta afirma que
"o `/ship:run` dentro da worktree termina em `done` e sinaliza `worker_done`".
Isso é falso por construção: `/ship:run` não conhece o Orca — e não pode conhecer,
pela regra de isolamento de driver. Quem cria a obrigação é o
`orchestration dispatch --inject`, que injeta o preâmbulo de ciclo de vida no
agente. Sem `--inject`, `check --wait` fica no timeout até estourar.

Consequências para o design, todas absorvidas pelo adapter (nada muda em `graph.sh`
nem no `pipeline.sh`):

- O prompt do worker continua sendo só `/ship:run <task>`; o `worker_done` vem do
  preâmbulo injetado, não de prosa nova em SKILL.
- `check --wait` devolve **uma** mensagem por vez. Com N workers em voo, o
  orquestrador chama `wait` N vezes — o loop da §4 da proposta já faz isso, porque
  cada `wait` é seguido de um `graph.sh next`.
- Timeout **não** é falha de worker. O verbo `wait` do driver sai 0 no timeout; é o
  `graph.sh next` que decide, e ele volta a emitir `state=wait`.
- `--wait` emite keepalives JSON em **stderr** a cada 15 s. O driver precisa
  descartar stderr, senão o parse do stdout do orquestrador contamina.

## 3. Prova 3 — `collect` (a crítica)

```
orca worktree show --worktree "id:<repo-id>::<path>" --json
```

Devolve `result.worktree.path` = `/Users/…/orca/workspaces/ship/<name>`, um caminho
absoluto no filesystem local, e `result.worktree.baseRef` = `refs/remotes/origin/main`.

Verificado de verdade, não pelo formato:

```
git -C /Users/…/orca/workspaces/ship/ship-graph-phase0-probe \
    diff --name-only refs/remotes/origin/main...HEAD     → exit 0
```

**A aresta de conflito por footprint real (§3.4 da proposta) é implementável.**
O fallback conservador (footprint declarado apenas) não é necessário.

Bônus para o driver: `baseRef` vem na própria resposta, então `graph.sh` não
precisa adivinhar a base do repo — o `collect` pode devolvê-la junto do path.

## 4. Prova 4 — `ask`

```
orca orchestration gate-create --task <task_id> \
  --question "<pergunta>" --options '["approve","reject"]' --json   → gate_id, status=pending
orca orchestration gate-list --task <task_id> --json                → o gate pendente
orca orchestration gate-resolve --id <gate_id> --resolution approve --json
                                                                    → status=resolved
```

Round-trip completo pela CLI. **Não verificado:** que o gate apareça e seja
resolvível pelo app mobile — isso é superfície de UI do Orca, fora do alcance da
CLI. O homolog em lote não depende disso para funcionar: com
`homolog-mode=defer` (§1.3 do plano) os relatórios se acumulam e são apresentados
ao final; `gate-create` é o canal opcional para resolver antes, não o mecanismo.

`gate-create` exige um `--task <task_id>` existente — ou seja, só é utilizável
depois que o `dispatch` da §1 criou a task. Para as perguntas do grafo que **não**
pertencem a uma task (deadlock de dependências, merge-fix estourado), o driver
precisa de uma task âncora ou cai para perguntar ao usuário no contexto. O
`driver-orca.sh` usa a task do nó em questão quando existe, e imprime a pergunta
caso contrário.

---

## Segunda rodada — o `driver-orca.sh` executado de verdade (2026-07-25)

As quatro provas acima validaram a **CLI**. Não validaram o driver: ele foi escrito
a partir delas e nunca tinha rodado. Rodou agora, contra worktrees reais
(`PROBE-001`, `PROBE-002`, ambos removidos ao final). Dois achados, os dois
consertados no driver.

### A. `dispatch --inject` cola, mas não submete — **bug bloqueante**

`dispatch` e `collect` funcionaram de primeira: os três IDs (`task_`, `ctx_`,
`term_`) e o id de worktree no formato `<repo-id>::<path>` saíram todos corretos,
e o `collect` devolveu `worktree=`, `branch=` e `base=` sem ressalva.

O `wait` estourou o timeout. O terminal do worker mostrava o preâmbulo **inteiro**
mais o bloco `=== TASK ===` parados na caixa de input, **sem submeter**. O agente
ficava `status: running`, ocioso, para sempre. Numa run real: `timeout=1` em todo
`wait`, o grafo nunca avança, e nada na saída indica por quê.

Um `terminal send --text "" --enter` submeteu o que estava no buffer e o agente
executou na hora. É o conserto, e está no `verb_dispatch`.

**`terminal wait --for tui-idle` não resolve** — foi a primeira hipótese (corrida
com o boot da TUI) e está errada: ele responde `satisfied: true` instantaneamente,
então não guarda nada. Descartado.

### B. `worker_done` depende do julgamento do worker — **resolvido, trocando handshake por artefato**

Com o prompt submetido, o agente respondeu e parou. **Não** mandou `worker_done` —
apesar do preâmbulo injetado instruir exatamente isso, e apesar de o mesmo prompt
trivial ter gerado `worker_done` na Fase 0. É julgamento do modelo, não mecanismo.

Consequência real: `timeout` no `wait` é ambíguo. Pode ser "worker ainda
trabalhando" (o caso comum e legítimo) ou "worker terminou e não avisou" — e o
`graph.sh next` trata os dois como `state=wait`, então o segundo caso trava o grafo.

Mitigação parcial que já existe: uma tarefa real (`/ship:run` completo, com fim
inequívoco) é bem mais provável de disparar o protocolo do que um "responda
'ready'" de um segundo. Mas isso é probabilidade, não garantia.

**O conserto veio de fora.** O fluxo do `orchestrate-project` (gkpacker) não usa
`orchestration` em lugar nenhum — sem `task-create`, sem `dispatch --inject`, sem
`worker_done`. O sinal de conclusão dele é o **PR no GitHub**, poluído por `gh`.

O princípio que isso expõe: *não peça ao agente que avise — observe um artefato
que ele foi obrigado a produzir*. Um agente esquece de mandar mensagem; ele não
esquece de ter deixado um arquivo no disco.

Para o Ship o artefato não é o PR (o `/ship:pr` roda uma vez, no fim), é
`homolog-approved.txt`: escrito pelo próprio `pipeline.sh`, em bash, quando a run
chega ao `done`. Daí `graph.sh poll`:

- nó com `homolog-approved.txt` no scratch → `landed`, sem handshake nenhum;
- progresso = contagem de linhas do `dispatch-log.md` (o `pipeline.sh dispatch`
  acrescenta uma por fase);
- sem progresso em 3 polls consecutivos → `stalled`, e o `next` emite `ask`
  nomeando o nó em vez de esperar para sempre.

Isso é agnóstico de runtime, então conserta `local` e `manual` junto — e elimina
de quebra o outro ponto de julgamento que existia: o orquestrador não decide mais
`land` vs `fail` lendo o relatório do worker.

`worker_done` continua sendo usado, mas só como **atalho**: se chegar, o `wait`
retorna mais cedo. Se não chegar, o `poll` resolve. O `--timeout-ms` do driver
caiu de 900s para 300s justamente porque o timeout deixou de ser um problema —
virou a cadência do poll.

### C. `/ship:run` não commita — **bug bloqueante do merge node, encontrado no caminho**

Investigando (B) apareceu um problema maior: `develop` escreve na árvore **sem
commitar** (`pipeline.sh:295`), e só o `/ship:pr` commita. A branch de um nó,
portanto, não tem commit algum — e o merge node fazia `git merge --no-ff <branch>`
integrando **nada**, com o nó marcado verde e a base vazia. Teria passado
despercebido na primeira feature inteira.

`graph.sh` agora sela a workspace em bash no momento do land (`git add -A` +
commit convencional derivado do título do nó) antes de qualquer merge. Não depende
de o worker lembrar de commitar.

## Estado deixado no runtime

O probe criou e removeu dois worktrees (`ship-graph-phase0-probe`,
`…-probe2`) — `worktree rm --force` confirmou `removed: true` em ambos, e
`worktree list` voltou ao conjunto anterior.

Permanece uma task de orquestração (`task_d5b429bf6769`, `completed`) e seu gate
resolvido. `orchestration reset` é global e apagaria estado alheio, então nada foi
resetado.

---

## Terceira rodada — a API contra a qual o driver foi escrito foi aposentada (2026-07-30)

Numa run real (`camada-de-marca-v1-agendx`, 23 nós) o `driver-orca` morreu na
**primeira** chamada:

```
orca orchestration task-create --spec ... --task-title ...
→ ok:false  code: legacy_read_only
  "This retained legacy coordinator could not prove its original process identity."
```

Nenhuma workspace chegou a existir, então nem havia o que inspecionar. A hipótese
inicial — "o Bash tool do agente não é um terminal gerenciado, logo não tem
identidade" — **está errada** e foi refutada por medição: falha igualmente de um
pane nativo do Orca, e `ORCA_TERMINAL_HANDLE` está presente no ambiente. Passar
`--from "$ORCA_TERMINAL_HANDLE"` também não muda nada.

A causa é outra: `orchestration coordinator-start` aparece hoje como
**`Retired: load the current orchestration skill`**. O driver foi escrito contra
esse esquema. Sem um **Run**, `task-create` cai no lookup do coordenador retido
daquele esquema, não consegue provar a identidade de processo original, e recusa.

O caminho atual, **os quatro verificados de um subprocesso comum**:

| Chamada | Resultado |
|---|---|
| `orchestration run-create --objective <o>` | `run_…`, `legacy: 0`, liga este terminal como `coordinator_handle` |
| `orchestration task-create … --run <run>` | `task_…` — **o `--run` é a diferença inteira** |
| `orchestration worker-start --task <t> --run <r> --agent claude --repo … --name … --worktree new-top-level` | cria a worktree Orca-managed, lança o agente, registra o dispatch e entrega o preâmbulo + `=== TASK ===` como `stage: input_accepted` |
| `worktree show` / `worker-stop --dispatch` | inalterados |

Duas consequências para o driver:

- **`deliver_prompt` foi removido.** Ele existia só para simular o que o
  `worker-start` já faz: a §A da segunda rodada (colar, conferir no buffer,
  mandar Enter em chamada separada) deixa de ser necessária, e com ela some a
  janela em que um send perdido deixava o worker ocioso com o brief não enviado.
- **A worktree passa a aparecer na UI do Orca**, porque é criada *através* do
  Orca. Um `git worktree` ao lado do repo (o que o `driver-local` faz) nunca
  aparece — é a resposta para "as worktrees não estão aparecendo direito".

`worker_done` continua sendo só atalho: quem decide conclusão é o
`graph.sh poll` lendo `homolog-approved.txt` (§B).

---

## O que muda no plano

Só o `driver-orca.sh` (Fase 3). `graph.sh`, `pipeline.sh`, o schema do grafo e as
Fases 1 e 2 seguem exatamente como planejados.

| Verbo | Implementação validada |
|---|---|
| `dispatch <task> <prompt> [<repo>]` | `task-create` → `worktree create --agent claude --no-parent --setup run` → `dispatch --inject`; imprime `handle=`, `worktree=`, `branch=`, `task=`, `dispatch=` |
| `wait [--timeout-ms N]` | `check --terminal <coord> --wait --types worker_done,escalation`; stderr descartado; timeout sai 0 |
| `ask <pergunta> [<task>]` | `gate-create` quando há task âncora; senão imprime a pergunta |
| `collect <task>` | `worktree show --worktree id:<id>`; imprime `worktree=`, `branch=`, `base=` |

---

## Quarta rodada — o driver estava certo; a eleição é que nunca era revista (2026-07-30)

A terceira rodada consertou `driver-orca.sh` e mediu que o caminho novo funciona.
Mesmo assim a run real continuou sem abrir uma única workspace do Orca. O log do
grafo (`camada-de-marca-v1-agendx`) explica por quê:

```
15:27Z init driver=orca     ← falhou no dispatch (API antiga)
15:28Z init driver=orca     ← falhou de novo
15:29Z init driver=local    ← fallback
21:14Z … 23:30Z             ← todas as levas seguintes, ainda em local
```

O `driver` é escrito no `meta.tsv` **uma vez**, no `init`. Nada nunca revisita
essa escolha. Então o fallback forçado por um runtime quebrado às 15:29 ficou em
vigor por mais oito horas, atravessando sessões, muito depois de o driver estar
consertado e o runtime respondendo — e **nenhuma saída do grafo dizia qual driver
estava em uso**, então a degradação só apareceu quando o usuário reparou que o
app estava vazio.

Duas medições que fecham o diagnóstico (2026-07-30, CLI vivo):

| Chamada | Resultado |
|---|---|
| `run-create` → `task-create --run` → `worker-start --worktree new-top-level --agent claude` | `state: ready`, `stage: input_accepted`, worktree criada e **registrada no app** |
| grafo de 2 nós via `graph.sh` com driver auto-eleito | duas workspaces dedicadas (`E2E-A`, `E2E-B`), uma por nó, cada uma com seu terminal e agente |

O que muda:

- **`graph.sh next` re-elege o driver** sempre que a escolha veio de probe e
  nenhum nó está preso ao driver atual (mesma guarda do `set --driver`). Um
  fallback deixa de ser permanente; a recuperação vira automática em vez de
  lembrada. Grafos escritos antes do campo `driver_chosen_by` contam como probe,
  então a run acima se cura sozinha no próximo `next`.
- **Um driver nomeado à mão é pinado** (`driver_chosen_by=explicit`) e nunca
  re-eleito — `--driver local` precisa significar local.
- **Todo driver declara o que produz** (`workspaces=` no `probe`), e `next` e
  `status` imprimem isso. "Rodando no driver que não abre nada" passa a ser
  visível na primeira vez, não horas depois.
- **`driver-orca` resolve o repo pela árvore de trabalho** quando o grafo não
  passa `--repo`, em vez de deixar o `worker-start` inferir o checkout do
  terminal coordenador — que não é necessariamente o repo do grafo.
