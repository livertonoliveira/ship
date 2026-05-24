# Changelog

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
