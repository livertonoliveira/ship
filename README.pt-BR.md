<p align="center">
  <img src="https://raw.githubusercontent.com/livertonoliveira/ship/main/docs/assets/logo.png" alt="Ship" height="96">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-Slash_Commands-7C3AED?style=for-the-badge" alt="Claude Code">
  <img src="https://img.shields.io/badge/Stack-Agnostic-10B981?style=for-the-badge" alt="Agnóstico de Stack">
  <img src="https://img.shields.io/badge/Zero_Dependências-FF6B35?style=for-the-badge" alt="Zero Dependências">
  <img src="https://img.shields.io/badge/Linear-Integration-5E6AD2?style=for-the-badge&logo=linear&logoColor=white" alt="Integração Linear">
  <img src="https://img.shields.io/badge/Licença-MIT-blue?style=for-the-badge" alt="Licença MIT">
</p>

<p align="center">
  Português · <a href="README.md">English</a>
</p>

---

<p align="center">
  <strong>Ship — Da ideia ao Pull Request, com um único comando.</strong><br>
  Especifique, implemente, teste, audite e entregue — sem precisar coordenar nada manualmente.
</p>

<p align="center">
  <a href="#o-problema">O Problema</a> ·
  <a href="#a-solução">A Solução</a> ·
  <a href="#instalação">Instalação</a> ·
  <a href="#início-rápido">Início Rápido</a> ·
  <a href="#comandos">Comandos</a> ·
  <a href="#configuração">Configuração</a>
</p>

---

## O Problema

Você tem uma ideia. Quer implementar uma feature. Com Claude Code, o código sai rápido — mas aí começa a parte chata:

- Escrever os requisitos num lugar
- Quebrar em tarefas num outro
- Gerar os testes (e lembrar de cobrir os casos de borda)
- Verificar se tem vulnerabilidades de segurança
- Analisar se vai ficar lento em produção
- Revisar se o código segue os padrões do projeto
- Criar o Pull Request com uma descrição decente
- Atualizar o tracker de tarefas

Cada uma dessas etapas acontece numa aba diferente, num prompt diferente, e boa parte do contexto se perde pelo caminho. Se a sessão cair no meio, começa tudo de novo.

---

## A Solução

Ship é um conjunto de comandos para Claude Code que automatiza esse fluxo inteiro.

Você descreve o que quer. O Ship quebra em tarefas, implementa, testa, revisa segurança e performance, e entrega um Pull Request com tudo documentado — com agentes rodando em paralelo em cada etapa.

```bash
/ship:spec "adicionar reset de senha"   # → cria projeto, milestones e tarefas
/ship:run TASK-42                        # → implementa, testa, revisa, audita
/ship:pr                                 # → Pull Request com relatório de qualidade
```

Isso é o fluxo completo. Cada comando faz uma etapa; você só intervém quando algo merece atenção.

### Antes vs. Depois

| Sem Ship | Com Ship |
|---|---|
| Planejamento em chat livre | Projeto com tarefas granulares e critérios de aceite |
| "Por favor, revise isso" | 3 agentes em paralelo: performance + segurança + qualidade de código |
| Testes escritos na hora, sem critério | Cenários definidos no spec, gerados automaticamente nos testes |
| Verificação de segurança manual | Scan OWASP automatizado em cada entrega, com gate de bloqueio |
| "Initial commit" repetido 20 vezes | Commits atômicos e padronizados por design |
| Sessão cai e contexto se perde | Artefatos persistidos no Linear ou em arquivos locais |

---

## Instalação

Ship é um plugin do Claude Code. Instale pelo marketplace:

```bash
claude plugin marketplace add livertonoliveira/ship
claude plugin install ship
```

Pronto. Não precisa de Node.js, banco de dados ou nenhum outro binário. Ship é puramente um conjunto de comandos que instrui o Claude Code — o único requisito é ter o Claude Code instalado.

### Atualização

```bash
claude plugin update ship@ship-marketplace
```

Reinicie o Claude Code após atualizar.

> **Atenção:** `claude plugin update ship` (sem o sufixo) falha com "Plugin not found". Use sempre o nome completo `ship@ship-marketplace`.

### Auto-update

Uma vez instalado o Ship via `claude plugin marketplace add`, o cliente Claude Code **atualiza o plugin automaticamente a cada startup** — nenhum passo manual necessário. O cliente compara o `plugin.json.version` cacheado localmente com a versão publicada no marketplace e baixa conteúdo novo quando diferem.

| O quê | Comportamento |
|-------|---------------|
| Gatilho | Em todo startup do Claude Code |
| Rede | Um `git fetch` contra o repo do marketplace |
| Notificação | Silenciosa — reinicie o Claude Code para usar os comandos atualizados |
| Fonte | `livertonoliveira/ship` no GitHub |

#### Forçando uma atualização

Se não quiser esperar pelo próximo startup, rode o comando da seção [Atualização](#atualização) acima.

#### Desabilitando ou fixando versão

Para rollouts em time/empresa que precisam de controle de versão, use [`managed-settings.json`](https://code.claude.com/docs/en/settings#managed-settings):

```json
{
  "extraKnownMarketplaces": {
    "ship-marketplace": {
      "source": "livertonoliveira/ship",
      "ref": "v2.5.1"
    }
  }
}
```

Fixar `ref` em uma tag congela o plugin nessa versão. Para opt-out completo do Ship após a instalação, use `/plugin disable ship`.

Veja a [doc oficial de marketplaces de plugin do Claude Code](https://code.claude.com/docs/en/plugin-marketplaces#version-resolution-and-release-channels) para regras completas de resolução de versão.

---

## Início Rápido

```bash
# 1. Inicialize o Ship no seu projeto (faça isso uma vez por projeto)
/ship:init

# 2. Descreva a feature que quer implementar
/ship:spec "adicionar notificações por e-mail para mudanças no status do pedido"

# 3. Execute a pipeline completa para uma tarefa criada pelo spec
/ship:run MOB-42

# 4. Crie o Pull Request com commits organizados e relatório de qualidade
/ship:pr
```

O `/ship:init` detecta automaticamente o stack do projeto e configura tudo. O `/ship:spec` cria um projeto estruturado com tarefas pequenas o suficiente para caber numa única sessão. O `/ship:run` executa todas as etapas de qualidade para aquela tarefa. O `/ship:pr` empacota tudo num Pull Request limpo.

> **Atalho:** se você já tem uma tarefa no Linear — ou quer implementar algo sem passar pelo spec — pode ir direto para o `/ship:run`. O spec não é pré-requisito; ele só enriquece a pipeline com critérios de aceite e cenários de teste pré-definidos.

---

## Comandos

Ship tem dois grupos de comandos com propósitos distintos.

### Pipeline — para o dia a dia de desenvolvimento

Esses comandos fazem parte do fluxo normal de entrega. Cada um analisa apenas **o que foi alterado** na tarefa atual.

| Comando | O que faz |
|---------|-----------|
| `/ship:init` | Inicializa o Ship no projeto — detecta stack, convenções, configura o Linear, cria `ship/config.md` |
| `/ship:spec` | Decompõe uma feature em tarefas granulares, define cenários de teste por critério de aceite, cria projeto no Linear com milestones e issues |
| `/ship:run` | Executa a pipeline completa para uma tarefa: planejamento → implementação → testes → performance → segurança → revisão → homologação |
| `/ship:plan` | Planejamento orientado a testes: decompõe a tarefa em módulos independentes e mapeia cada cenário para um slot de teste — um único `plan.md` que develop e test consomem, mantendo código e testes em sincronia |
| `/ship:develop` | Lê o plano e implementa o código seguindo as convenções do projeto, paralelizando um worker por módulo (pode rodar sozinho ou dentro do `/ship:run`) |
| `/ship:test` | Gera e executa testes unitários, de integração e e2e a partir do test contract do plano (cai para os cenários quando não há plano) |
| `/ship:perf` | Analisa performance do diff — detecta o tipo de projeto e adapta os agentes |
| `/ship:security` | Scan de segurança OWASP do diff com 3 agentes em paralelo por categoria de ataque |
| `/ship:review` | Revisão de código focada em SOLID, DRY, KISS, Clean Code e consistência com o projeto |
| `/ship:analyze` | Detecta drift entre spec, código e testes — gate PASS/WARN/FAIL |
| `/ship:homolog` | Apresenta o relatório final de qualidade e aguarda aprovação |
| `/ship:pr` | Cria o Pull Request com commits atômicos e relatório de qualidade agregado |

### Auditoria — para revisões periódicas do projeto

Esses comandos analisam o **projeto inteiro**, não apenas o diff atual. Use antes de releases, em revisões periódicas de saúde, ou quando quiser entender o estado geral do sistema.

| Comando | O que faz |
|---------|-----------|
| `/ship:audit:backend` | Auditoria de performance de backend em todo o projeto — 3 agentes em paralelo |
| `/ship:audit:frontend` | Auditoria de performance de frontend — roteia para Next.js (5 camadas) ou metodologia genérica (11 categorias) |
| `/ship:audit:database` | Auditoria de banco de dados — detecta e usa a metodologia de MongoDB, PostgreSQL ou MySQL |
| `/ship:audit:security` | Auditoria AppSec completa — OWASP Top 10, mapeamento CWE, nota A-F, PoC para achados críticos e altos |
| `/ship:audit:tests` | Auditoria de cobertura de testes — mapeia critérios de aceite contra testes existentes e reporta lacunas por camada |
| `/ship:audit:run` | Executa todas as auditorias aplicáveis em paralelo e consolida os resultados num único relatório |

> **Importante:** comandos de auditoria **nunca** são chamados automaticamente pelo `/ship:run`. Eles existem para ser disparados manualmente quando fizer sentido — não a cada tarefa.

---

## Configuração

Quando você roda `/ship:init`, o Ship cria um arquivo `ship/config.md` na raiz do projeto. Esse arquivo controla o comportamento de toda a pipeline.

```markdown
# Ship Config

## Project
- Name: Meu Projeto
- Type: backend          # backend | frontend | fullstack | mobile | prompt-toolkit

## Linear Integration
- Configured: yes
- Team: Engineering
- Team ID: <seu-team-id>
- In Progress Status: In Progress   # nome do estado "started" do time (auto-detectado; ex. "Em andamento")
- Done Status: Done                 # nome do estado "completed" do time (auto-detectado; ex. "Concluído")

## Pipeline Profile
- profile: standard      # lite | standard | strict

## Pipeline Phases
- dev: enabled
- test: enabled
- perf: enabled
- security: enabled
- review: enabled
- homolog: enabled
- pr: enabled

## Gate Behavior
- on_fail: ask           # ask | fix | defer
- on_warn: ask           # ask | fix | pass
- on_fail_rerun: surgical   # surgical | full

## Conventions
- Artifact language: pt-BR  # Idioma para specs, issues, docs, milestones, relatórios
- Commit style: Conventional Commits
- Atomic commits: one logical change per commit

## Test Scope
- unit: enabled
- integration: enabled
- e2e: disabled

## Scenario Depth
- depth: full            # none | light | full
```

### Perfis de Pipeline

O campo `profile` define o comportamento padrão da pipeline:

| Perfil | Descrição |
|--------|-----------|
| `lite` | Só implementação e testes — ideal para iterações rápidas |
| `standard` | Todas as fases com profundidade equilibrada — padrão recomendado |
| `strict` | Todas as fases com verificações exaustivas — gates bloqueiam até em warnings |

Você pode ajustar fases individualmente em `Pipeline Phases`. O `profile` define os defaults; as entradas individuais sobrescrevem.

### Gates de Qualidade

Em cada fase, o Ship classifica os achados por severidade e decide o que fazer:

- Achados `critical` ou `high` → gate **FAIL** → pipeline para
- Achados `medium` → gate **WARN** → pipeline pausa e pergunta ao usuário
- Achados `low` ou nenhum → gate **PASS** → pipeline continua

O campo `on_fail` controla o que acontece num FAIL: `ask` (pausa e pergunta), `fix` (agente tenta corrigir automaticamente) ou `defer` (cria uma issue de acompanhamento e continua). O campo `on_warn` faz o mesmo para WARNs: `ask`, `fix` ou `pass` (continua sem ação). O campo `on_fail_rerun` controla o escopo quando a fase roda de novo: `surgical` (só os arquivos com problemas) ou `full` (fase inteira do zero).

### Armazenamento: Linear ou Local

Ship funciona em dois modos dependendo de você ter o Linear MCP configurado:

**Modo Linear (recomendado):** todos os artefatos — propostas, designs, tarefas, relatórios de qualidade — ficam no Linear como documentos e comentários de issues. O único arquivo local é o `ship/config.md`.

**Modo Local (alternativa):** os artefatos são escritos em `ship/changes/<feature>/` como arquivos markdown.

```
ship/
├── config.md
├── changes/
│   └── <nome-da-feature>/
│       ├── proposal.md
│       ├── design.md
│       ├── tasks.md
│       ├── report-<tarefa>.md
│       └── tracking.md
└── audits/
    ├── backend-<data>.md
    ├── frontend-<data>.md
    ├── database-<data>.md
    ├── security-<data>.md
    ├── tests-<data>.md
    └── run-<data>.md
```

### Escopo de Testes

O campo `Test Scope` controla quais camadas de teste o `/ship:test` gera durante a pipeline:

| Tipo de projeto | unit | integration | e2e |
|-----------------|------|-------------|-----|
| `prompt-toolkit` / biblioteca | enabled | disabled | disabled |
| `backend` / `fullstack` | enabled | enabled | disabled |
| `frontend` | enabled | disabled | disabled |
| `monorepo` | enabled | enabled | disabled |
| `mobile` | enabled | disabled | disabled |

Camadas desabilitadas não são geradas durante o pipeline normal. Para auditar e preencher essas lacunas, use `/ship:audit:tests`.

> O `/ship:analyze` detecta drift apenas nas camadas habilitadas; o `/ship:audit:tests` audita todas as camadas do projeto independente dessa configuração.

### Profundidade dos Cenários

O campo `Scenario Depth` controla quantos cenários de teste o `/ship:spec` cria por critério de aceite:

| Valor | Comportamento |
|-------|---------------|
| `none` | Nenhum cenário — spec contém apenas ACs e requisitos |
| `light` | Apenas o caminho feliz por AC |
| `full` | Conjunto completo: caminho feliz + casos de borda + casos de erro (padrão) |

Quando `depth` é `light` ou `full`, cada cenário recebe tags como `@SC-01`, `@AC-02`. Essas tags viajam por toda a pipeline:

- `/ship:plan` — mapeia cada `@SC-XX` para um módulo e um slot de teste numa única interpretação
- `/ship:develop` — implementa código para satisfazer cada `@SC-XX` (seguindo o plano)
- `/ship:test` — gera um teste por cenário sem precisar rederivá-los
- `/ship:analyze` — correlaciona cenários com testes e reporta o que está coberto
- `/ship:audit:tests` — faz essa correlação em todo o projeto por camada

---

## Requisitos

| Requisito | Observação |
|-----------|------------|
| Claude Code | Obrigatório — Ship é um plugin do Claude Code |
| Linear MCP | Opcional — habilita o Modo Linear para armazenamento de artefatos |

Nenhuma outra dependência. Sem Node.js. Sem banco de dados. Sem binário para instalar ou manter.

---

## Licença

MIT
