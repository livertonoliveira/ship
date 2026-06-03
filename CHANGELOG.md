# Changelog

## 2.7.7 — 2026-06-03

### Features
- **Develop evidence gate (`/ship:run`, step 2.6)**: o pipeline deixou de confiar no auto-report do `develop`. O `run` captura um snapshot do working tree antes da fase de develop e, depois dela, exige prova de mutação real. Zero mutação numa task nova (baseline vazio) → gate `fail` e pipeline para, em vez de um `pass` silencioso sobre uma árvore intocada. Re-run onde o trabalho já existia → `warn` e segue.

### Fixes
- **Orquestradores `develop`/`test` não fazem mais "narrate-and-return"**: rodando em Haiku e sem ferramentas de escrita, os orquestradores forkados podiam narrar o plano e reportar `pass` sem despachar nenhum worker via Agent tool — o pipeline reportava sucesso com a working tree zerada. Os prompts foram endurecidos (bloco CRITICAL "act, not narrate", seção 3 marcada como MANDATORY ACTION e self-check obrigatório antes de retornar), tornando a omissão um hard failure.

## 2.0.0 — 2026-05-24

### ⚠️  Breaking changes
- **Distribuição agora é plugin puro (sem `install.sh`)**. Skills são distribuídas com patterns já inlinados em build-time. Usuários instalam via `claude plugin install ship` — não rodam mais nenhum script manual.
- **Removido**: `install.sh`, `update.sh`, skill `/ship:update`.
- **Removido**: pasta `ship/patterns/` no projeto consumidor não é mais necessária nem usada (pode ser deletada à vontade).

### Como migrar (usuários antigos)
1. Desinstalar o Ship antigo: apagar `.claude/commands/ship/` e `ship/patterns/` no seu projeto.
2. Instalar via marketplace: `claude plugin install ship`.
3. Continuar usando os mesmos slash commands (`/ship:spec`, `/ship:run`, etc.) — comportamento idêntico.

### Internals
- Layout: source em `src/` na raiz do repo (skills, patterns, shared templates). Build output em `plugins/ship/skills/` — committed, descoberto pelo Claude Code via default discovery (sem campo `skills` no manifest).
- Build script: `plugins/ship/scripts/build.js` (inliner de `@ship/...`).
- CI valida que `plugins/ship/skills/` está em sync com `src/` em toda PR/tag.
