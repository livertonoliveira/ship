---
name: ship:audit:frontend
description: "Ship Audit: project-wide frontend performance audit. Auto-routes to Next.js methodology (5 layers) or generic methodology (11 categories) based on ship/config.md."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
context: fork
---

# Ship Audit Frontend — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Frontend` → framework (Next.js, React, Vue, Angular, Svelte, ...)
- `Project Type` → backend | frontend | fullstack | monorepo
- `Stack` → runtime, build tool, package manager

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`) and # Stack Detection

Read these fields from `ship/config.md` to understand the project's stack:

- **Runtime**: Node.js, Python, Go, Java, Rust, Ruby, PHP, .NET, etc.
- **Framework**: NestJS, Express, Fastify, Hono, Django, Flask, FastAPI, Gin, Echo, Spring Boot, Rails, Laravel, ASP.NET, etc.
- **Database**: MongoDB, PostgreSQL, MySQL, Redis, SQLite, DynamoDB, etc.
- **Frontend**: Next.js, React, Vue, Angular, Svelte, Astro, Nuxt, Remix, SolidJS, etc.
- **Project Type**: `backend` | `frontend` | `fullstack` | `monorepo`
- **Workspaces**: (monorepo only) list of workspaces and their types
- **Build tool**: esbuild, webpack, vite, turbopack, tsc, gradle, maven, cargo, etc.
- **Test framework**: Vitest, Jest, Mocha, pytest, go test, RSpec, PHPUnit, JUnit, Playwright, Cypress, etc.
- **Package manager**: pnpm, npm, yarn, pip, poetry, go mod, cargo, maven, gradle, bundler, composer, etc.
- **Lint command**: eslint, prettier, ruff, golangci-lint, rubocop, phpcs, etc.
- **Typecheck command**: tsc --noEmit, pnpm typecheck, mypy, go vet, etc.

## How to detect (when `ship/config.md` is absent or incomplete)

Probe the project root for these signal files:

| Signal file / dependency | Indicates |
|--------------------------|-----------|
| `package.json` | Node.js runtime; inspect `dependencies`/`devDependencies` for framework |
| `package-lock.json` | npm |
| `pnpm-lock.yaml` | pnpm |
| `yarn.lock` | yarn |
| `pnpm-workspace.yaml` / `lerna.json` / `nx.json` / `turbo.json` | monorepo |
| `package.json → workspaces` field | monorepo |
| `nest-cli.json` or `@nestjs/*` dep | NestJS |
| `next.config.*` | Next.js |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pyproject.toml` or `requirements.txt` | Python |
| `pom.xml` or `build.gradle` | Java |
| `Gemfile` | Ruby |
| `composer.json` | PHP |
| `*.csproj` | .NET |
| `mongoose` / `@typegoose` dep | MongoDB |
| `pg` / `prisma` / `typeorm` dep | PostgreSQL |
| `mysql2` / `mysql` dep | MySQL |
| `redis` / `ioredis` dep | Redis |
| `vitest.config.*` or `vitest` dep | Vitest |
| `jest.config.*` or `jest` dep | Jest |
| `playwright.config.*` dep | Playwright |
| `cypress.config.*` dep | Cypress |
| `next.config.*` / `vite.config.*` / `angular.json` present, no server entry | `frontend` project type |
| `package.json` with server entry (`main` points to a server file), no frontend config | `backend` project type |
| Both a frontend config file and a server entry present | `fullstack` project type |.

Routing hint (decides nothing — the agent owns the final routing): if `Frontend: Next.js` or a `next.config.*` file exists at the project root, the agent uses the Next.js path (5 heuristics); otherwise the generic path (11 categories).

## 3. Invoke ship-audit-frontend agent

Use the Agent tool with `subagent_type: ship:ship-audit-frontend`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>

## Stack
Frontend: <framework>
Project Type: <type>
Stack: <stack>

## Config
<severity overrides if present>
```

The agent handles framework routing, heuristic selection, parallel sub-agents, consolidation, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
