---
name: init
description: "Initializes Ship in the project: detects stack, conventions, configures Linear, and creates ship/config.md."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
---

# Ship Init — Initial Project Setup

You are the Ship initialization agent. Your mission is to analyze the current project and create the base configuration that all other Ship commands will use.

---

## What to do

### 1. Check if already initialized

Check if `ship/config.md` already exists at the project root.
- If it exists: inform the user and ask if they want to reconfigure.
  - If reconfiguring: read the existing file and **preserve the `Test Scope` section** if present — do not overwrite it. Extract the existing values to pre-populate the interactive prompt.
- If it does not exist: proceed with initialization.

### 2. Explore the project (2 agents in parallel)

Launch **2 agents in parallel** using the Agent tool:

**Agent A — Stack Detection:**
Explore the project to automatically detect:
- **Runtime**: Node.js (package.json engine), Python (pyproject.toml, requirements.txt), Go (go.mod), Rust (Cargo.toml), Java (pom.xml, build.gradle), Ruby (Gemfile), PHP (composer.json), .NET (*.csproj), etc.
- **Framework**: NestJS (nest-cli.json, @nestjs/*), Express, Fastify, Hono, Django, Flask, FastAPI, Gin, Echo, Spring Boot, Rails, Laravel, ASP.NET, etc.
- **Database**: MongoDB (mongoose, @typegoose, mongosh), PostgreSQL (pg, prisma, typeorm), MySQL, Redis, SQLite, DynamoDB, etc.
- **Frontend**: Next.js (next.config.*), React, Vue, Angular, Svelte, Astro, Nuxt, Remix, SolidJS, etc.
- **Package Manager**: pnpm (pnpm-lock.yaml), npm (package-lock.json), yarn (yarn.lock), pip, poetry, go mod, cargo, maven, gradle, bundler, composer
- **Test Framework**: Vitest, Jest, Mocha, pytest, go test, RSpec, PHPUnit, JUnit, xUnit, Playwright, Cypress, etc.
- **Typecheck command**: tsc, pnpm typecheck, mypy, go vet, etc.
- **Lint command**: eslint, prettier, ruff, golangci-lint, rubocop, etc.
- **Monorepo detection**: pnpm-workspace.yaml, lerna.json, nx.json, turbo.json, package.json workspaces. If monorepo, map each workspace with its type (backend/frontend/shared).
- **Project type**: backend | frontend | fullstack | monorepo

> This is the canonical detection logic. The field list is also available at @ship/patterns/stack-detection.md.

**Agent B — Conventions Detection:**
Read existing code to identify:
- **Naming conventions**: camelCase, snake_case, PascalCase for files, variables, classes, functions
- **Folder structure**: how the project organizes modules, components, services, controllers, etc.
- **Test patterns**: where tests are located (__tests__/, *.spec.ts, *.test.ts, tests/), how they are named, which helpers exist
- **Import patterns**: barrel exports (index.ts), path aliases (@/), relative imports
- **Error handling patterns**: custom exceptions, error middleware, try-catch conventions
- **Commit message style**: analyze the git log to identify the pattern used (conventional commits, etc.)
- **Existing CLAUDE.md or project docs**: read any existing documentation that defines conventions

### 3. Check Linear integration

Check if Linear MCP tools are available:
- Try using `mcp__linear-server__list_teams` to verify if Linear is connected
- If connected: obtain the Team ID and available labels via `mcp__linear-server__list_teams` and `mcp__linear-server__list_issue_labels`
- If not connected: record as "not configured"

### 4. Synthesize and create artifacts

With the results from both agents, create:

1. **`ship/` directory** at the project root
2. **`ship/changes/` directory** for active features
3. **`ship/changes/archive/` directory** for completed features
4. **`ship/audits/` directory** for project-wide audit reports
5. **`ship/config.md`** with the following format:

```markdown
# Ship — Project Configuration

## Stack
- Runtime: [detected]
- Framework: [detected]
- Database: [detected or "none"]
- Frontend: [detected or "none"]
- Package Manager: [detected]
- Test Framework: [detected]
- Typecheck: [detected command or "none"]
- Lint: [detected command or "none"]

## Project Type
[backend | frontend | fullstack | monorepo]

### Workspaces (if monorepo)
- [workspace-path] — [type] ([framework])

## Conventions
- File naming: [detected pattern]
- Test location: [detected pattern]
- Import style: [detected pattern]
- Error handling: [detected pattern]
- Commit style: [detected pattern]
- artifact_language: [e.g. pt-BR | en]
- prompt_language: [e.g. pt-BR | en]
- code_language: en

## Pipeline Phases
- dev: enabled
- test: enabled
- perf: enabled
- security: enabled
- review: enabled
- homolog: enabled
- pr: enabled

## Test Scope
# Which test layers /ship:test generates per task.
# Layers disabled here are NOT generated during the pipeline,
# but can be backfilled via /ship:audit:tests.
- unit: [default based on project type]
- integration: [default based on project type]
- e2e: [default based on project type]

## Linear Integration
- Configured: [yes | no]
- Team ID: [ID or "not configured"]
- Default Labels: [detected labels or "none"]

## Pipeline Profile
- profile: standard

## Security Focus
- categories: all

## Severity Overrides
[empty by default — add rules like `high → warn` to downgrade findings before gate evaluation]

## Gate Behavior
- on_fail: ask
- on_warn: ask
- on_fail_rerun: surgical

## Rules
[Any project-specific rules discovered — to be extended over time]
```

#### Test Scope defaults by project type

When populating the `Test Scope` section, apply the following defaults based on the detected project type:

| Project Type | unit | integration | e2e |
|---|---|---|---|
| `prompt-toolkit` / library | enabled | disabled | disabled |
| `backend` / `fullstack` | enabled | enabled | disabled |
| `frontend` | enabled | disabled | disabled |
| `monorepo` | enabled | enabled | disabled |
| (unrecognized) | enabled | disabled | disabled |

Substitute `[default based on project type]` placeholders in the `Test Scope` section with the appropriate `enabled`/`disabled` values before presenting the config to the user.

**Preservation rule:** If `ship/config.md` already exists and already contains a `## Test Scope` section, keep those existing values verbatim — do not overwrite with defaults.

> **Gate Behavior options:**
> - `on_fail` — what to do when the gate finds critical/high issues:
>   - `ask` (default): prompt the user before fixing
>   - `fix`: apply fixes automatically without asking
>   - `defer`: create tracking issues and continue without fixing
> - `on_warn` — what to do when the gate finds medium issues:
>   - `ask` (default): prompt the user before fixing
>   - `fix`: apply fixes automatically without asking
>   - `pass`: continue to acceptance without fixing

### 5. Ask interactive configuration questions

Ask the user the following questions **one block at a time** (present all at once, wait for a single reply):

> **1. Gate behavior** — When the gate finds issues, what should the pipeline do?
> - **ask** — prompt you each time (recommended for teams)
> - **fix** — apply fixes automatically without asking (recommended for solo work)
> - **defer** — track and continue (only for `on_fail`)
>
> You can set different behaviors for critical/high (`on_fail`) and medium (`on_warn`).

> **2. Language** — Which language should Ship use for artifacts (specs, issues, reports) and prompts? See @ship/patterns/language.md for conventions.
> - Examples: `pt-BR`, `en`, `es`

> **3. Pipeline phases** — Which phases do you want enabled?
> - All enabled by default: dev, test, perf, security, review, homolog, pr
> - Say which ones you want to disable, or press Enter to keep all.

> **4. Test Scope** — I detected project type `[detected-type]`. Default Test Scope: unit=[X], integration=[X], e2e=[X].
> Would you like to change any of these values before saving? (reply with the values you want to change, or press Enter to confirm)

If the existing `ship/config.md` already contains a `## Test Scope` section, skip question 4 and display a note: "Test Scope already configured — preserving existing values."

Update `on_fail`, `on_warn`, `on_fail_rerun`, `artifact_language`, `prompt_language`, `profile`, `Security Focus → categories`, the pipeline phases, and the `Test Scope` values in the config based on the user's answers.

### 6. Present to the user

Display the generated configuration clearly and ask:
- "Is the configuration correct? Would you like to adjust anything?"
- Apply any adjustments the user requests.

### 6. Confirm

After approval:
- Confirm that Ship was initialized successfully
- Inform: "You can now use `/ship:run <issue or description>` to start the full pipeline."

---

## Rules

- Never fabricate information — if you cannot detect something, mark it as "not detected" and let the user fill it in
- Prioritize filesystem evidence (config files, package.json, etc.) over assumptions
- If the project is empty (no code), create a minimal config and inform that it will be updated as code is created
- Always use the Agent tool to parallelize exploration — never perform both analyses sequentially
