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
  <strong>Ship — Pipeline de desenvolvimento como slash commands do Claude Code — zero dependências</strong><br>
  Da ideia bruta ao Pull Request entregue — especifique, implemente, teste, audite e entregue com um único comando.
</p>

<p align="center">
  <a href="#o-que-é-ship">O que é Ship</a> ·
  <a href="#instalação">Instalação</a> ·
  <a href="#início-rápido">Início Rápido</a> ·
  <a href="#comandos">Comandos</a> ·
  <a href="#configuração">Configuração</a> ·
  <a href="#requisitos">Requisitos</a>
</p>

---

## O que é Ship

Claude Code é uma ferramenta poderosa. A Ship a transforma em uma pipeline de desenvolvimento completa.

Entregar uma feature do jeito "normal" com um LLM (Large Language Model — modelo de linguagem grande) significa malabarismo entre uma dúzia de abas: requisitos, tarefas, testes, revisão de segurança, análise de performance, descrição de PR (Pull Request), atualização do tracker, disciplina de commit. Cada uma consome contexto. Cada uma está a um prompt de ser esquecida.

A Ship troca esse caos por uma **pipeline determinística e repetível** construída inteiramente com slash commands do Claude Code:

- **Um comando especifica a feature inteira.** `/ship:spec "adicionar reset de senha"` cria um projeto Linear com milestones, labels e tarefas granulares — cada uma dimensionada para caber em uma única sessão.
- **Um comando entrega a tarefa.** `/ship:run TASK-ID` executa develop → test → performance → security → review → acceptance, com agentes em paralelo e um gate de qualidade em cada fase.
- **Um comando entrega o PR.** `/ship:pr` produz Conventional Commits atômicos e um PR com relatório de qualidade agregado.

Como a Ship é puramente um conjunto de slash commands do Claude Code (prompt-toolkit), ela **não requer binário, runtime nem banco de dados**. Instale uma vez, funciona em qualquer lugar que o Claude Code rode.

### Antes vs. Depois da Ship

| Sem Ship | Com Ship |
|---|---|
| Planejamento de feature em chat livre | Projeto Linear com tarefas granulares (<400 linhas cada) |
| "Por favor, revise isso" | 3 agentes em paralelo: performance + segurança + SOLID/DRY/KISS |
| Cobertura de testes ad-hoc | Unit + integration + e2e gerados em paralelo |
| Análise OWASP manual | Scan de segurança automatizado em cada diff com gate de política |
| "Initial commit" × 20 | Conventional Commits atômicos por design |
| Sessão cai no meio da pipeline | Artefatos persistidos no Linear ou em markdown local |

---

## Instalação

### Plugin (método principal)

```bash
claude plugin marketplace add livertonoliveira/ship
claude plugin install ship
```

O plugin registra todos os slash commands `/ship:*` no Claude Code automaticamente. Nenhuma configuração adicional é necessária para começar.

### curl (alternativa)

```bash
curl -fsSL https://raw.githubusercontent.com/livertonoliveira/ship/main/install.sh | bash
```

Este comando coloca os arquivos de comando em `.claude/commands/ship/` no seu projeto e os registra no Claude Code.

### Zero dependências

A Ship **não** requer:
- Node.js ou npm
- PostgreSQL ou qualquer banco de dados
- Nenhum binário ou runtime instalado

É um prompt-toolkit puro: slash commands que instruem agentes do Claude Code. O único requisito é o próprio Claude Code.

---

## Início Rápido

```bash
# 1. Inicializar a Ship no projeto (executar uma vez por projeto)
/ship:init

# 2. Especificar uma feature — cria projeto Linear, milestones e tarefas
/ship:spec "adicionar notificações por e-mail para mudanças no status do pedido"

# 3. Executar a pipeline completa para uma tarefa
/ship:run MOB-42

# 4. Entregar o PR com commits atômicos e relatório de qualidade
/ship:pr
```

Esse é o fluxo completo. Cada etapa se apoia na anterior: `spec` cria tarefas estruturadas, `run` executa a pipeline completa de develop → test → qualidade para cada tarefa, e `pr` empacota tudo em um Pull Request limpo e revisável.

---

## Comandos

### Comandos de Pipeline

| Comando | Propósito |
|---------|-----------|
| `/ship:init` | Inicializar a Ship no projeto — detecta stack, convenções, configura o Linear, cria `ship/config.md` |
| `/ship:spec` | Especificação detalhada: decompor uma feature em tarefas granulares (<400 linhas), criar projeto Linear com milestones e issues |
| `/ship:run` | Pipeline completa para uma tarefa: develop → test → perf → security → review → analyze → homolog |
| `/ship:develop` | Implementar código seguindo as convenções do projeto (pode rodar standalone ou dentro do `/ship:run`) |
| `/ship:test` | Gerar e executar testes — unit, integration e e2e — com 3 agentes em paralelo |
| `/ship:perf` | Análise de performance do diff — detecta o tipo de projeto e adapta os agentes |
| `/ship:security` | Scan de segurança OWASP (Open Web Application Security Project) do diff com 3 agentes em paralelo por categoria de ataque |
| `/ship:review` | Revisão de código focada em SOLID, DRY, KISS, Clean Code e consistência do projeto |
| `/ship:analyze` | Detecção de drift: mapear spec→código→testes, detectar lacunas, gate PASS/WARN/FAIL |
| `/ship:homolog` | Relatório final de qualidade + aprovação de aceite pelo usuário |
| `/ship:pr` | Criar PR (Pull Request) com Conventional Commits atômicos e relatório de qualidade agregado |
| `/ship:update` | Atualizar todos os arquivos de comando da Ship para a versão mais recente |

### Comandos de Auditoria

Os comandos de auditoria são **abrangentes ao projeto** — eles escaneiam toda a base de código em busca de problemas sistêmicos. Execute-os periodicamente ou antes de releases. Diferente das fases de pipeline, as auditorias não são limitadas ao diff.

| Comando | Propósito |
|---------|-----------|
| `/ship:audit:backend` | Auditoria de performance de backend para todo o projeto — 3 agentes em paralelo, sensível ao stack |
| `/ship:audit:frontend` | Auditoria de performance de frontend para todo o projeto — roteia automaticamente para Next.js (5 camadas) ou genérico (11 categorias) |
| `/ship:audit:database` | Auditoria de banco de dados para todo o projeto — roteia para metodologia MongoDB, PostgreSQL ou MySQL |
| `/ship:audit:security` | Auditoria AppSec (Application Security) para todo o projeto — OWASP Top 10, mapeamento CWE, pontuação A-F, PoC para críticos/altos |
| `/ship:audit:run` | Executar todas as auditorias aplicáveis em paralelo; produz um relatório de gate consolidado |
| `/ship:audit:tests` | Auditoria de cobertura de testes para todo o projeto — mapeia AC/REQ ↔ testes existentes, reporta lacunas por camada |

---

## Configuração

Após o `/ship:init`, a Ship cria o arquivo `ship/config.md` na raiz do seu projeto. Este arquivo controla todos os aspectos da pipeline.

```markdown
# Ship Config

## Project
- Name: Meu Projeto
- Type: backend          # backend | frontend | fullstack | mobile | prompt-toolkit

## Linear Integration
- Configured: yes
- Team: Engineering
- Team ID: <seu-team-id>

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
```

### Perfis de Pipeline

| Perfil | Descrição |
|--------|-----------|
| `lite` | Feedback rápido — apenas dev + test |
| `standard` | Equilibrado — todas as fases, profundidade média |
| `strict` | Máxima qualidade — todas as fases, verificações exaustivas, gates bloqueiam no warn |

Cada fase pode ser habilitada ou desabilitada individualmente. O `profile` define os padrões; as entradas em `Pipeline Phases` os sobrescrevem.

### Comportamento dos Gates

Os gates param ou redirecionam a pipeline com base na severidade dos achados:

- Achados `critical` ou `high` → gate **FAIL** → pipeline para
- Achados `medium` → gate **WARN** → pipeline pausa e pergunta ao usuário
- Achados `low` ou nenhum → gate **PASS** → pipeline continua

A configuração `on_fail` controla o que acontece em um gate FAIL: `ask` (pausa e pergunta ao usuário), `fix` (agente tenta corrigir automaticamente) ou `defer` (cria uma issue de acompanhamento e continua). A configuração `on_warn` controla gates WARN: `ask`, `fix` ou `pass` (continua sem ação). A configuração `on_fail_rerun` controla o escopo da reexecução: `surgical` (apenas os arquivos com problemas) ou `full` (reexecuta a fase inteira do zero).

### Integração com o Linear

Quando o Linear MCP (Model Context Protocol) está configurado, a Ship opera em **Modo Linear**: todos os artefatos (propostas, designs, tarefas, relatórios de qualidade) ficam no Linear como documentos e comentários de issues. Zero arquivos locais são criados além do `ship/config.md`.

Sem o Linear, a Ship recai para o **Modo Local**: os artefatos são escritos em `ship/changes/<feature>/` como arquivos markdown.

### Test Scope

A seção `Test Scope` no `ship/config.md` controla quais camadas de teste o `/ship:test` gera durante a pipeline:

```markdown
## Test Scope
- unit: enabled        # Testes unitários (sempre recomendado)
- integration: enabled # Testes de integração/API
- e2e: disabled        # Testes end-to-end (via /ship:audit:tests para backfill)
```

**Padrões por tipo de projeto:**

| Tipo | unit | integration | e2e |
|------|------|-------------|-----|
| `prompt-toolkit` / biblioteca | enabled | disabled | disabled |
| `backend` / `fullstack` | enabled | enabled | disabled |
| `frontend` | enabled | disabled | disabled |
| `monorepo` | enabled | enabled | disabled |
| `mobile` | enabled | disabled | disabled |

Camadas desabilitadas **não** são geradas durante a pipeline. Use `/ship:audit:tests` para auditar e preencher a cobertura de camadas desabilitadas em todo o projeto.

> **Observação:** O `/ship:analyze` detecta drift apenas nas camadas habilitadas do Test Scope; o `/ship:audit:tests` audita **todas** as camadas em todo o projeto, independente da configuração da pipeline.

---

## Requisitos

| Requisito | Observações |
|-----------|-------------|
| Claude Code | Obrigatório — a Ship é um plugin do Claude Code |
| Linear MCP | Opcional — habilita o Modo Linear para armazenamento de artefatos |

Nenhuma outra dependência. Sem Node.js. Sem banco de dados. Sem binário para instalar ou manter.

---

## Modos de Armazenamento

### Modo Linear (recomendado)

Todos os artefatos ficam no Linear — zero arquivos locais exceto `ship/config.md`:

- **Proposta e Design** → Documentos do Linear vinculados ao projeto
- **Tarefas** → Issues do Linear com milestones e labels
- **Relatórios de Qualidade** → Comentários nas issues de tarefas
- **Acompanhamento** → Sub-issues do Linear

### Modo Local (alternativa)

Todos os artefatos ficam em `ship/changes/<feature>/` como markdown:

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

---

## Licença

MIT
