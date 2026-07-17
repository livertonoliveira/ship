---
name: ship:audit:tests
description: "Ship Audit: project-wide test coverage analysis — correlates AC/REQ from spec with existing tests using Jaccard similarity, gate PASS/WARN."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
context: fork
---

# Ship Audit Tests — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` section → enabled/disabled status for `unit`, `integration`, `e2e` layers
- If the `Test Scope` section is absent → treat all three layers as `enabled`

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`), # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. and # Stack Detection

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

## 3. Invoke ship-audit-tests agent

Use the Agent tool with `subagent_type: ship:ship-audit-tests`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>

## Config
Test Scope:
- unit: <enabled|disabled>
- integration: <enabled|disabled>
- e2e: <enabled|disabled>
```

The agent handles AC/REQ↔test correlation (Jaccard), gap classification by layer, gate decision, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
