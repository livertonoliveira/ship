# Pressure testing de skills

O harness de pressure testing responde a uma pergunta concreta: uma instrução de
um skill (`SKILL.md`) muda o resultado observável quando é removida? Se não muda,
ela é candidata a poda. Este documento cobre a filosofia por trás do harness, como
rodá-lo (`--record` / `--replay`), como ler o relatório gerado e um caso real de
instrução podada usando o próprio harness como evidência.

## Filosofia

A regra do braço de controle é simples: **se o controle não mostra a falha, não
escreva a instrução.**

Cada caso de pressure testing compara dois braços rodando a mesma tarefa:

- **treatment** — o skill completo, como está em `src/skills/<skill>/SKILL.md`.
- **control** — o mesmo skill, mas com uma seção específica removida (o `anchor`
  declarado no `case.json`).

Se uma asserção observável (ex.: o schema do plano gerado, a presença de um
arquivo, um passo do pipeline) passa igualmente bem nos dois braços, a seção
removida no controle não estava contribuindo para aquele comportamento — ela é
"noop" e pode ser podada do skill. Se o controle falha e o treatment passa, a
seção é "justified": ela existe porque previne uma falha real, mensurável.

O harness deliberadamente não depende de julgamento subjetivo sobre "a instrução
parece útil" ou "a instrução está bem escrita". Ele depende de asserções
observáveis e reproduzíveis sobre artefatos gerados (planos, código, status de
fase). Isso evita o viés de manter instruções por precaução ou por "parecer que
ajuda" quando elas não mudam nenhum resultado mensurável.

## How-to: record vs replay

O ponto de entrada é `scripts/pressure-run.sh <caso> [--record|--replay]`.

### `--replay` (modo padrão, usado em CI)

Lê os cassettes já commitados no repositório e nunca invoca um driver de LLM.
É determinístico, rápido e gratuito — por isso é o modo padrão e o único
rodado em CI.

```bash
bash scripts/pressure-run.sh plan-instruction --replay
```

### `--record` (Tier 3, manual, consome tokens)

Roda o skill de verdade, headless, N vezes por braço, via
`claude --print --plugin-dir`, e grava os artefatos resultantes como novos
cassettes. Requer o driver declarado em `$PRESSURE_DRIVER` (padrão `claude`)
disponível no `PATH`. Use `--record` apenas quando precisar gerar ou atualizar
cassettes de um caso — nunca em CI.

```bash
PRESSURE_DRIVER=claude bash scripts/pressure-run.sh plan-instruction --record
```

A variável `PRESSURE_DRIVER` existe justamente para permitir stubar o driver em
testes automatizados do próprio harness, sem depender do binário real do
Claude Code.

### Layout de caso e cassette

Cada caso vive em `pressure/cases/<caso>/`:

```
pressure/cases/<caso>/
├── case.json                          # manifesto: skill, input, braços, asserções, reps
└── arms/
    └── <braço>/                       # treatment | control
        └── rep-NN/                    # uma repetição gravada
            ├── plan.md
            ├── code/
            └── phase-status.md
```

O `case.json` declara o `skill` alvo, o arquivo de `input`, o `anchor` do braço
de controle (a seção a ser removida do `SKILL.md` para gerar o build de
controle), a lista de `assertions` a rodar e o número de `reps` por braço.

## Como ler o relatório

O agregador (`plugins/ship/scripts/pressure/aggregate.js`) resume os resultados
de cada braço em `passRate` (fração de repetições que passaram na asserção) e
`variance` (variância amostral do resultado binário pass/fail). A partir disso
calcula:

- **delta** — `treatment.passRate - control.passRate`.
- **verdict** — o veredito final, calculado assim:
  - `inconclusive` se `min(treatment.n, control.n) < minReps` (por padrão,
    `DEFAULT_MIN_REPS = 3`) — repetições insuficientes para confiar no
    resultado.
  - `justified` se `delta >= threshold` (por padrão, `DEFAULT_THRESHOLD = 0.2`)
    — o treatment claramente supera o controle, a instrução importa.
  - `noop` caso contrário — controle e treatment se comportam de forma
    equivalente, a instrução é prunável.

## Caso documentado de poda: `plan-instruction`

O caso `pressure/cases/plan-instruction/case.json` testa o skill `plan`,
removendo no braço de controle a seção "4.5. AC outcome completeness (close
sub-AC coverage gaps)" de `src/skills/plan/SKILL.md`, com a asserção
`planSchema` e `reps: 3`.

Rodando o replay contra os cassettes commitados:

```bash
bash scripts/pressure-run.sh plan-instruction --replay
```

produz a seguinte tabela:

| caso | asserção | treat passRate | treat var | ctrl passRate | ctrl var | delta | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| plan-instruction | planSchema | 1.00 | 0.00 | 1.00 | 0.00 | 0.00 | noop |

Com o treatment e o controle atingindo o mesmo `passRate` (1.00) e a mesma
variância (0.00), o delta é zero e o veredito é `noop`: a seção "4.5. AC
outcome completeness" não muda a taxa de sucesso do `planSchema`, esteja ela
presente ou removida do skill. Essa evidência é o que classifica a seção como
prunável.

Esse caso valida na prática o critério de poda descrito em
[`docs/framework-comparison/spec-04-noop-pruning-budget.md`](framework-comparison/spec-04-noop-pruning-budget.md):
instruções cujo braço de controle não mostra degradação mensurável no
resultado observável não justificam permanecer no skill.
