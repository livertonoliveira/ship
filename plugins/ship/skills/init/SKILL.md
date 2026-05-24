---
name: init
description: "Initializes Ship in the project: detects stack, conventions, configures Linear, and creates ship/config.md."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "haiku"
---

# Ship Init — Initial Project Setup

You are the Ship initialization agent. Your mission is to analyze the current project and create the base configuration that all other Ship commands will use.

---

## What to do

### 1. Check if already initialized

Check if `ship/config.md` already exists at the project root.
- If it exists: inform the user and ask if they want to reconfigure.
  - If reconfiguring: read the existing file and **preserve the `Test Scope` and `Scenario Depth` sections** if present — do not overwrite them. Extract the existing values to pre-populate the interactive prompt.
- If it does not exist: proceed with initialization.

### 2. Explore the project (2 agents in parallel)

Launch **2 agents in parallel** using the Agent tool. For BOTH agents, pass `model: "sonnet"` explicitly to the Agent tool call — they read source code and infer patterns (reasoning work). The orchestrator itself runs on Haiku per # Model Routing Policy

---

## Principle

Ship pins the model per skill instead of inheriting from the session. This decouples cost
control from quality: users can pick Haiku as their session model to economize across the
weekly limit, and Ship still guarantees Sonnet on the skills that actually reason (implementation,
analysis, generation, correlation). Symmetrically, template/control-flow skills (report
rendering, findings aggregation, PR expansion, orchestration) are pinned to Haiku because they
gain nothing from a higher tier.

This applies whether a skill is invoked standalone (`/ship:develop`) or as a sub-agent inside
an orchestrator (`ship:run` dispatching `develop`). Both layers reinforce each other: the
frontmatter `model:` field overrides the session tier, and an explicit `model:` parameter on
an Agent tool dispatch overrides the frontmatter.

---

## Rules

1. **Use only tier aliases** — `"haiku"`, `"sonnet"`, `"opus"`. Never use versioned IDs like
   `claude-haiku-4-5-20251001`. Aliases resolve dynamically to the latest model in that tier,
   eliminating churn when models are upgraded.

2. **Template phases declare `model: "haiku"` in SKILL.md frontmatter.**

3. **Reasoning phases declare `model: "sonnet"` in SKILL.md frontmatter.** They never inherit
   from the parent session — Sonnet is pinned so the skill behaves identically whether invoked
   standalone or via an orchestrator. Reasoning phases include: `develop`, `test`, `perf`,
   `security`, `review`, `analyze`, `spec`, and all `audit:*` skills except `audit:run`.

4. **Reasoning agents launched by Haiku orchestrators must pass `model: "sonnet"` explicitly**
   to the Agent tool call. Redundant with rule 3 (the frontmatter would already pin Sonnet),
   but kept as a belt-and-suspenders so the dispatch site is self-documenting and any future
   reasoning skill added without `model: "sonnet"` in frontmatter still runs on Sonnet when
   dispatched. The symmetric rule also holds: **consolidation/template agents inside Sonnet
   contexts** (e.g., the Step 5 agent in `ship:audit:run`) must pass `model: "haiku"` explicitly.

---

## Phase classification

| Skill / Phase         | Tier    | Reason                                          |
|-----------------------|---------|-------------------------------------------------|
| `ship:homolog`        | haiku   | Report rendering, findings consolidation        |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:run`            | haiku (orchestrator) | Template/control-flow: file reads, deterministic diff classification, gate eval, dispatch. Spawns Sonnet agents explicitly for reasoning phases. |
| `ship:init`           | haiku (orchestrator) | Config-file template writing + interactive Q&A. Spawns Sonnet agents explicitly for stack/conventions detection. |
| `ship:audit:run` consolidation agent | haiku | Aggregates pre-structured audit reports |
| `ship:develop`        | sonnet   | Implementation — needs full reasoning           |
| `ship:test`           | sonnet   | Test generation — needs full reasoning          |
| `ship:perf`           | sonnet   | Performance analysis — needs full reasoning     |
| `ship:security`       | sonnet   | Security analysis — needs full reasoning        |
| `ship:review`         | sonnet   | Code review — needs full reasoning              |
| `ship:analyze`        | sonnet   | Drift detection — needs full reasoning          |
| `ship:spec`           | sonnet   | Deep specification — needs full reasoning       |
| `ship:audit:*`        | sonnet   | Project-wide audits — needs full reasoning      |

---

## Orchestrator-on-Haiku pattern

When a skill is mostly **control-flow and dispatch** — reading files, running deterministic
bash for classification, evaluating gates, spawning sub-agents, aggregating results — its body
gains nothing from a session-tier model. The expensive reasoning lives inside the sub-agents.

For these skills, apply the **Orchestrator-on-Haiku pattern**:

1. Set the skill's frontmatter to `model: "haiku"`.
2. In every Agent tool dispatch inside the skill, pass `model: "sonnet"` explicitly for any
   sub-agent that does reasoning work (implementation, analysis, generation, correlation).
3. Sub-agents that themselves do template/aggregation work inherit Haiku from the parent — no
   explicit model parameter needed (e.g., `homolog` dispatched by `run` keeps Haiku because
   its own SKILL.md frontmatter already declares `model: "haiku"`).

**Boundary**: only apply this pattern when the orchestrator's body is genuinely deterministic.
If the orchestrator itself needs to make non-trivial judgment calls (e.g., dependency inference,
ambiguous classification), either keep it at session tier or rewrite the judgment as a
deterministic rule before downgrading. See the multi-task note in `ship:run` for an example
mitigation (dependency inference removed in favor of deterministic Linear milestone order).

---

## How to apply

### In SKILL.md frontmatter (for skills that are themselves template phases):

```yaml
---
name: ship:homolog
model: "haiku"
# ... other fields
---
```

### In Agent tool calls (Haiku orchestrator launching reasoning sub-agents):

Pass `model: "sonnet"` when calling the Agent tool for reasoning work:

```
Use the Agent tool to execute development. Pass model: "sonnet" to this agent —
implementation requires full reasoning.
```

### In Agent tool calls (Sonnet orchestrator launching consolidation sub-agents):

Pass `model: "haiku"` when calling the Agent tool for consolidation work:

```
Use the Agent tool to consolidate results. Pass model: "haiku" to this agent —
it performs template/report aggregation, not reasoning.
```

---

## Pattern classification (skill-patterns-convention.md)

`model-routing.md` is a **bundle pattern** (> 30 lines). Reference in SKILL.md via:

```
For model routing rules, read the file at ./ship/patterns/model-routing.md completely.
```.

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

> This is the canonical detection logic. The field list is also available at # Stack Detection

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

## Scenario Depth
# How rigorously /ship:spec captures Gherkin scenarios per acceptance
# criterion, threaded through develop/test/analyze.
#   none  — no Scenarios section; pipeline behaves exactly as pre-feature
#   light — every AC gets >=1 scenario (nominal + dominant error)
#   full  — nominal + key edge + error per AC (Scenario Outline for combinatorics)
- depth: full

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

#### Scenario Depth default

`## Scenario Depth → depth` defaults to `full` for **all** project types (no per-type table). Write `- depth: full` unless the user changes it in question 5.

**Preservation rule:** If `ship/config.md` already exists and already contains a `## Scenario Depth` section, keep the existing value verbatim — do not overwrite with the default.

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

> **2. Language** — Which language should Ship use for artifacts (specs, issues, reports) and prompts? See # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above. for conventions.
> - Examples: `pt-BR`, `en`, `es`

> **3. Pipeline phases** — Which phases do you want enabled?
> - All enabled by default: dev, test, perf, security, review, homolog, pr
> - Say which ones you want to disable, or press Enter to keep all.

> **4. Test Scope** — I detected project type `[detected-type]`. Default Test Scope: unit=[X], integration=[X], e2e=[X].
> Would you like to change any of these values before saving? (reply with the values you want to change, or press Enter to confirm)

If the existing `ship/config.md` already contains a `## Test Scope` section, skip question 4 and display a note: "Test Scope already configured — preserving existing values."

> **5. Scenario Depth** — How thoroughly should `/ship:spec` capture Gherkin scenarios per acceptance criterion? Default: `full`.
> - **full** — nominal + key edge + error scenario per AC (recommended)
> - **light** — nominal + dominant error scenario per AC
> - **none** — no scenarios; pipeline behaves exactly as before this feature
> Press Enter to keep `full`, or reply with `light` / `none`.

If the existing `ship/config.md` already contains a `## Scenario Depth` section, skip question 5 and display a note: "Scenario Depth already configured — preserving existing value."

Update `on_fail`, `on_warn`, `on_fail_rerun`, `artifact_language`, `prompt_language`, `profile`, `Security Focus → categories`, the pipeline phases, the `Test Scope` values, and `Scenario Depth → depth` in the config based on the user's answers.

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
