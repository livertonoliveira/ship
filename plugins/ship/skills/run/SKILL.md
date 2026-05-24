---
name: run
description: "Full development pipeline for a task: develop → test → perf → security → review → analyze → homolog. Works on 1 task by default, or N tasks / entire project if requested."
argument-hint: "<task-id | linear-issue-id | --project project-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "haiku"
---

# Ship Run — Development Pipeline

You are the main Ship development orchestrator. Your mission is to take a task (from Linear or local markdown) and drive it through the full development pipeline: implementation → testing → quality checks → user acceptance. You maximize the use of parallel agents at every stage.

**With Linear:** Task details, context, and quality reports all live in Linear. No local files needed.
**Without Linear:** Everything lives in `ship/changes/<feature>/` as markdown files.

**Input received:** $ARGUMENTS

---

## Prerequisites

### 1. Check initialization

Check if `ship/config.md` exists at the project root.
- If it does NOT exist: inform the user they need to run `/ship:init` first and STOP.

### 2. Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

### 3. Check for specification

- **Linear mode**: The user should provide a Linear issue ID. If they don't, ask for one.
- **Local mode**: Check if `ship/changes/` contains feature folders with tasks. If none exist, inform the user to run `/ship:spec` first.

---

## Detect input mode

Analyze `$ARGUMENTS` to determine what to work on:

### Single task (default, recommended)
- **Linear issue ID** (e.g., `ABC-123`): Work on this specific task. Fetch details via `mcp__linear-server__get_issue`.
- **Local task ID** (e.g., `TASK-001`): Find the task in `ship/changes/<feature>/tasks.md`.

### Multiple tasks
- **`--project <name>`**: Work through ALL pending tasks in the specified project/feature, one at a time, in milestone order.
- **`--milestone <name>`**: Work through all pending tasks in a specific milestone.
- **Multiple IDs** (e.g., `ABC-123 ABC-124 ABC-125`): Work on these specific tasks in order.

**Default behavior**: Work on **1 task at a time**. After completing each task, ask the user: "Task complete. Continue to the next task, or stop here?"

---

## Pipeline Execution (per task)

For each task, execute the following phases:

### 0.5. Initialize shared scratch dir

> See # Run Context — Shared Scratch Between Agents

Temporary scratch pattern used by the `/ship:run` orchestrator to share context
between phase agents (develop, test, perf, security, review).

---

## Root directory

```
.context/ship-run/<task-id>/
```

`<task-id>` is the Linear issue identifier (e.g., `MOB-1140`) or, in local mode,
the feature slug (e.g., `my-feature`). The directory is ephemeral — never commit it
(see `.gitignore`).

> **`<task-id>` must contain only `[a-zA-Z0-9_-]`. Never use values containing `/`, `..`, or spaces.**

---

## Canonical files

| File | Written by | Read by | Content |
|------|-----------|---------|---------|
| `stack.md` | orchestrator (run) | all agents | detected stack summary — language, runtime, framework, test runner |
| `diff.md` | orchestrator (run) | perf, security, review | output of `git diff` for the branch — full diff of new/modified code |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `phase-status.md` | orchestrator (creates); agents (append) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `pre-quality-snapshot.sha` | orchestrator (run) | pr agent | HEAD commit SHA before quality phases — used to build the PR diff |
| `jaccard.json` | analyze agent | analyze agent (re-run) | Jaccard similarity matrix cache — keyed by diff + spec SHA-256 hashes; reused when hashes match to avoid redundant computation |

### `stack.md` format

```markdown
# Stack

- Language: TypeScript
- Runtime: Node.js 20+
- Framework: NestJS
- Test runner: vitest
- Package manager: npm
```

### `diff.md` format

Literal output of `git diff main...HEAD` (or the configured range), without truncation.

### `test-failures.md` format

Always written by the test agent — even if all tests passed (header-only = zero failures):

```markdown
# Test Failures

- src/auth/auth.service.ts (3 failures)
- src/users/users.repo.ts (1 failure)
```

When all tests pass, the file contains only the header:

```markdown
# Test Failures
```

Header-only (no bullet items) or absent file both indicate all tests passed.

### `phase-status.md` format

Each phase appends one row when it completes. Re-run iterations appear as additional rows with incremented run numbers. Timestamps are ISO-8601 UTC.

```markdown
# Phase Status

| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |
|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|
| develop | #1 | 2026-05-01T10:00:00Z | - | pass | 0 | 0 | 0 | 0 | |
| test | #1 | 2026-05-01T10:01:00Z | - | pass | 0 | 0 | 0 | 0 | |
| perf | #1 | 2026-05-01T10:02:00Z | src/runner.ts | warn | 0 | 0 | 2 | 1 | N+1 query detected |
| security | #1 | 2026-05-01T10:02:00Z | src/runner.ts, config.ts | pass | 0 | 0 | 0 | 0 | |
| review | #1 | 2026-05-01T10:02:00Z | src/runner.ts | pass | 0 | 0 | 0 | 0 | |
| perf | #2 | 2026-05-01T10:05:00Z | src/runner.ts | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### `pre-quality-snapshot.sha` format

Single-line file with the commit SHA:

```
a1b2c3d4e5f6...
```

### `jaccard.json` format

Written and read by the `analyze` agent (pipeline mode only). Invalidated whenever `diff_hash` or `spec_hash` changes.

```json
{
  "diff_hash": "<sha256 of diff.md content>",
  "spec_hash": "<sha256 of concatenated REQ-XX/AC-XX descriptions>",
  "matrix": {
    "REQ-01": { "code": ["src/foo.ts:10"], "score": 0.7 },
    "REQ-02": { "code": ["src/bar.ts:55"], "score": 0.3 },
    "AC-01":  { "tests": ["test/foo.test.ts:42"], "score": 0.9 },
    "AC-02":  { "tests": [], "score": 0.0 }
  }
}
```

- `diff_hash` and `spec_hash` are used as a compound cache key. If either changes, the entire matrix is recomputed.
- `matrix` maps each REQ-XX/AC-XX ID to its best-match file(s) and highest Jaccard score.
- `code` lists matched source file locations (`<path>:<line>`); `tests` lists matched test file locations.
- Absent file means the cache was computed in standalone mode (no scratch dir) — no `jaccard.json` is written in that case.

---

## Read/write conventions

- **Orchestrator** (`run.md`): sole owner of **creating** the directory and **writing**
  `stack.md`, `diff.md`, and `pre-quality-snapshot.sha` before launching any agent.
  Also creates `phase-status.md` with the empty header row at pipeline start.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files.
  The only write allowed is **appending** rows to `phase-status.md` upon phase completion.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files |
| During pipeline | Agents read and append as needed |
| End of `/ship:pr` | Orchestrator removes `.context/ship-run/<task-id>/` (recursive) |
| `--keep-context` flag in `/ship:pr` | Directory is preserved for manual inspection |

The parent directory `.context/ship-run/` may hold multiple `<task-id>/` subdirs if
parallel pipelines are running — never remove the parent, only the completed task's subdir.

---

## Inline context slicing (fan-out optimization)

When the orchestrator dispatches N parallel sub-agents, each agent opens a fresh conversation with no shared prompt cache. Passing large shared artifacts (diff, Design, proposal) to every agent multiplies token costs: **N × file size + N × cache miss**.

**Pattern:** the orchestrator reads each shared artifact **once**, slices it into per-agent subsets, and passes the slice **inline** in each agent's prompt. Agents must never re-read the original file.

### Slicing rules

- Always include enough surrounding context for the agent to understand scope:
  - For diffs: include the `diff --git a/...` file header + the full `@@ ... @@` hunk header + ±3 surrounding context lines for each included hunk.
  - For design/proposal docs: include the full subsection (heading + body) relevant to the agent's scope.
- If a hunk or section does not clearly belong to any agent's scope, include it in **all** agents' slices (conservative fallback).
- The orchestrator must not truncate content that agents need to make correct decisions — smaller is better, but correctness comes first.

### Which phases use this pattern

| Phase | Shared artifact sliced | Slice dimension |
|-------|------------------------|-----------------|
| `ship:security` | diff | by OWASP category (Injection / Auth / Data+Config) |
| `ship:test` | proposal ACs + file list | by test layer (unit / integration / e2e) |
| `ship:develop` | Design document | by module / independent implementation unit | for canonical file formats and lifecycle rules.

After the trace is initialized, set up the shared scratch directory for this run. Use the issue ID (e.g., `MOB-1147`) as `<task-id>` — it must match `[a-zA-Z0-9_-]` only.

```bash
mkdir -p .context/ship-run/<task-id>
```

Then populate the canonical files in a single batch:

1. **`stack.md`** — Run stack-detection (see # Stack Detection

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
| Both a frontend config file and a server entry present | `fullstack` project type |): read `ship/config.md` and extract Language, Runtime, Framework, Test runner, Package manager, and any other relevant fields. Write the result in the canonical format:

   ```markdown
   # Stack

   - Language: <value>
   - Runtime: <value>
   - Framework: <value>
   - Test runner: <value>
   - Package manager: <value>
   ```

   Write this content to `.context/ship-run/<task-id>/stack.md`.

2. **`diff.md`** — Run the following and write the full output (no truncation) to `.context/ship-run/<task-id>/diff.md`:

   ```bash
   git diff origin/main...HEAD
   ```

3. **`phase-status.md`** — Create the file with only the header (no rows yet):

   ```markdown
   # Phase Status

   | Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |
   |-------|-----|-----------|-------|------|----------|------|--------|-----|-------|
   ```

   Write to `.context/ship-run/<task-id>/phase-status.md`.

4. **`pre-quality-snapshot.sha`** — Capture the current HEAD SHA and write it as a single line:

   ```bash
   git rev-parse HEAD
   ```

   Write the SHA to `.context/ship-run/<task-id>/pre-quality-snapshot.sha`.

Log to the user:
```
Run context: .context/ship-run/<task-id>/ (stack + diff cached)
```

### 0.7. Diff Classification

> See # Diff Classifier — Deterministic Heuristic

Classifies the diff in `.context/ship-run/<task-id>/diff.md` into one of four classes
and adjusts which quality agents run in Phase 4 of `/ship:run`.

> **No LLM calls.** All classification is computed via bash-parseable rules only.

---

## Classification Criteria

### Line count

Count changed lines (add `+` and remove `-` lines, excluding `+++`/`---` headers):

```bash
grep -E '^[+-]' diff.md | grep -Ev '^(\+\+\+|---)' | wc -l
```

### Logical file count

Count unique modified source files, excluding documentation/config-only extensions:

```bash
grep '^+++ b/' diff.md | sed 's|^+++ b/||' \
  | grep -Ev '\.(md|json|lock|txt|ya?ml)$' | sort -u | wc -l
```

### New endpoint detection

Check for new route/endpoint patterns added by the diff:

```bash
grep '^+' diff.md | grep -Ev '^\+\+\+' \
  | grep -E "route\(|app\.(get|post|put|patch|delete)\(|@(Get|Post|Put|Patch|Delete)\(" \
  | wc -l
```

### Sensitive path detection

Check if any added file in the diff touches a sensitive path:

```bash
grep '^+++ b/' diff.md | sed 's|^+++ b/||' \
  | grep -E '^(auth/|payment/|query|migrations/)' | wc -l
```

Default sensitive prefixes: `auth/`, `payment/`, `query`, `migrations/`.
Override by adding `## Sensitive Paths` to `ship/config.md` (see format below).

---

## Classification Rules (evaluated top-down, first match wins)

| Class | Conditions |
|-------|-----------|
| `trivial` | ALL of: (a) only files with ext `*.md`, `*.json`, `*.lock`, `*.txt`, `*.yml`, `*.yaml` modified; (b) zero sensitive path matches; (c) total diff < 50 lines |
| `large` | total diff > 1000 lines OR logical files > 10 |
| `minor` | total diff < 100 lines AND logical files ≤ 1 AND zero new endpoint patterns |
| `normal` | everything else (default) |

> `large` is checked before `minor` so a 1200-line single-file change is `large`, not `minor`.

---

## Sensitive Paths Override (in `ship/config.md`)

When the `## Sensitive Paths` section is present, its entries **replace** (not extend) the defaults:

```markdown
## Sensitive Paths
# Optional — paths that force 'normal' classification even for trivial diffs.
# Format: one path prefix per line (relative to repo root).
# Defaults if section is absent: auth/, payment/, query, migrations/
# - auth/
# - payment/
# - migrations/
```

Parse the section: extract non-comment lines starting with `- ` and strip the leading `- `.

---

## Behavior per Class

| Class | Quality agents | Log message |
|-------|---------------|-------------|
| `trivial` | Skip all (`perf`, `security`, `review`) — mark all as gate=PASS | `Diff trivial — fases de qualidade puladas` |
| `minor` | Run 1 combined security agent only; skip `perf` and `review` | `Diff minor — security combinado, perf/review pulados` |
| `normal` | Current behavior — up to 3 parallel agents | `Diff normal — fases de qualidade completas` |
| `large` | Current behavior — up to 3 parallel agents | `Diff large — fases de qualidade completas` |

### `trivial` — phase-status.md entries

Append one PASS row for each skipped quality phase:

```
| perf     | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
| security | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
| review   | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
```

### `minor` — combined security agent

Launch a single security agent instructed to cover all three OWASP categories
(Injection + Auth + Data/Config) in one pass. Write findings to the same
`security-findings-<task-id>.md` file as normal mode. `perf` and `review` rows
in `phase-status.md` are written as gate=PASS with notes `diff minor — pulado`.

---

## Output

Write the classification result to:

```
.context/ship-run/<task-id>/diff-class.txt
```

Content: a single word — `trivial`, `minor`, `normal`, or `large`.

---

## Compute & Log

After writing `diff-class.txt`, log to the user:

```
Diff class: <class> (<reason>)
```

Where `<reason>` is a short human-readable explanation, e.g.:
- `trivial` → `only doc/config files, 12 lines, no sensitive paths`
- `minor` → `48 lines, 1 logical file, no new endpoints`
- `normal` → `default classification`
- `large` → `1 240 lines changed` for the full heuristic reference.

Classify the diff **deterministically** (no LLM) using the rules below. Read `diff.md` from the scratch dir and `ship/config.md` for sensitive-path overrides.

**Step 1 — Compute metrics** (run inline bash, no agent needed):

```bash
DIFF=".context/ship-run/<task-id>/diff.md"

# Total changed lines (+/- excluding headers)
LINES=$(grep -E '^[+-]' "$DIFF" | grep -Ev '^(\+\+\+|---)' | wc -l | tr -d ' ')

# Logical files modified (excluding doc/config extensions)
LOGICAL_FILES=$(grep '^+++ b/' "$DIFF" | sed 's|^+++ b/||' \
  | grep -Ev '\.(md|json|lock|txt|ya?ml)$' | sort -u | wc -l | tr -d ' ')

# All modified files (to detect trivial-only)
ALL_FILES=$(grep '^+++ b/' "$DIFF" | sed 's|^+++ b/||' | sort -u | wc -l | tr -d ' ')
DOC_ONLY_FILES=$(grep '^+++ b/' "$DIFF" | sed 's|^+++ b/||' \
  | grep -E '\.(md|json|lock|txt|ya?ml)$' | sort -u | wc -l | tr -d ' ')

# New endpoint patterns
NEW_ENDPOINTS=$(grep '^+' "$DIFF" | grep -Ev '^\+\+\+' \
  | grep -cE 'route\(|app\.(get|post|put|patch|delete)\(|@(Get|Post|Put|Patch|Delete)\(' || true)
```

**Step 2 — Read sensitive paths** from `ship/config.md`:
- If `## Sensitive Paths` section is present, parse non-comment lines starting with `- ` and strip the `- ` prefix → use as sensitive prefixes.
- If section is absent, use defaults: `auth/`, `payment/`, `query`, `migrations/`.

**Step 3 — Check sensitive path matches**:

```bash
SENSITIVE_HITS=$(grep '^+++ b/' "$DIFF" | sed 's|^+++ b/||' \
  | grep -cE '^(auth/|payment/|query|migrations/)' || true)
# (replace the grep -E pattern with the actual sensitive prefixes from step 2)
```

**Step 4 — Classify** (first match wins):

| Check | Class |
|-------|-------|
| `ALL_FILES == DOC_ONLY_FILES` AND `SENSITIVE_HITS == 0` AND `LINES < 50` | `trivial` |
| `LINES > 1000` OR `LOGICAL_FILES > 10` | `large` |
| `LINES < 100` AND `LOGICAL_FILES <= 1` AND `NEW_ENDPOINTS == 0` | `minor` |
| (everything else) | `normal` |

**Step 5 — Write result**:

```bash
echo "<class>" > .context/ship-run/<task-id>/diff-class.txt
```

**Step 6 — Log to user**:

```
Diff class: <class> (<reason>)
```

Where `<reason>` is a brief explanation (e.g., `only doc/config files, 12 lines, no sensitive paths`).

### 1. Load task context

**Linear mode:**
1. Use `mcp__linear-server__get_issue` to get task title, description, acceptance criteria, labels, milestone
2. Use `mcp__linear-server__get_project` to get the project context
3. Use `mcp__linear-server__list_documents` + `mcp__linear-server__get_document` to read the Proposal and Design documents linked to the project
4. Read `ship/config.md` (see # Stack Detection

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
| Both a frontend config file and a server entry present | `fullstack` project type | for stack detection logic).
5. Build the **effective phase set** for this run (applies to both Linear and Local mode):
   1. Read `Pipeline Profile → profile` from `ship/config.md` (default: `standard` if the field is absent or unknown)
   2. Look up that profile's phase defaults in `# Pipeline Profiles

A profile is a named preset that enables or disables pipeline phases in bulk. It is set in `ship/config.md` under `## Pipeline Profile`.

## Available profiles

| Phase | `lite` | `standard` | `strict` |
|-------|:------:|:----------:|:--------:|
| dev | ✓ | ✓ | ✓ |
| test | | ✓ | ✓ |
| perf | | | ✓ |
| security | | | ✓ |
| review | | ✓ | ✓ |
| homolog | | ✓ | ✓ |
| pr | ✓ | ✓ | ✓ |

## Precedence rule

Individual phase overrides in `Pipeline Phases` always take precedence over the profile. The profile only sets the default state of each phase; any `enabled`/`disabled` entry in `Pipeline Phases` overrides that default for that specific phase.

Example: `profile: lite` + `test: enabled` in `Pipeline Phases` → tests run even though `lite` excludes them.

## Usage examples

### Prototype / proof of concept (`lite`)
Fast iteration — only dev and PR, no quality gates.
```
## Pipeline Profile
- profile: lite
```

### Internal library (`standard`)
Balanced coverage — dev, tests, review, and homologation; skip heavy perf/security scans.
```
## Pipeline Profile
- profile: standard
```

### Critical product / external exposure (`strict`)
Maximum quality — all phases enabled, full OWASP and performance scans on every task.
```
## Pipeline Profile
- profile: strict
```

#### Strict-exclusive: pre-PR audit gate

When `profile: strict`, `/ship:pr` automatically triggers `/ship:audit:run` **before** creating the PR. The consolidated gate result determines what happens next:

| Gate | Behavior |
|------|----------|
| PASS | PR creation proceeds normally |
| WARN | Pipeline pauses — user is asked to confirm before continuing |
| FAIL | PR creation is blocked until all critical/high findings are resolved |

This guarantees that no PR is merged from a `strict` project with unresolved critical or high audit findings. For `lite` and `standard` profiles, no audit is triggered automatically during `/ship:pr`.

See the `ship:pr` skill § "Strict-exclusive" for the full decision tree and exact user-facing messages.`. If the profile name is not recognized, fall back to `standard` and warn the user.
   3. For each phase (`dev`, `test`, `perf`, `security`, `review`, `analyze`, `homolog`, `pr`): if `Pipeline Phases` has an explicit `enabled`/`disabled` entry, that override wins; otherwise use the profile default
   4. **Log to the user** before starting any phase:
      - Format: `Profile: <name> → fases ativas: <list> | puladas por profile: <list>`
      - If any explicit `Pipeline Phases` entry overrode the profile default, append: `| override: <phase>: <enabled|disabled>`
      - Example (no overrides): `Profile: lite → fases ativas: dev, pr | puladas por profile: test, perf, security, review, homolog`
      - Example (with override): `Profile: lite | override: test: enabled → fases ativas: dev, test, pr | puladas por profile: perf, security, review, homolog`

6. Extract `Artifact language` from `ship/config.md → Conventions` (e.g., `pt-BR`). Store as `artifact_language`. This value is the **orchestrator-owned language context** — inject it explicitly into every phase agent prompt you dispatch in steps 2–8: include `Artifact language: <resolved-value>` in the agent's instructions, replacing `<artifact_language>` with the actual value you resolved (e.g., write `Artifact language: pt-BR`, not the placeholder). Phase SKILL.md files will use this injected value instead of re-loading `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

7. Read `Scenario Depth → depth` from `ship/config.md` (default `full` if the section is absent). This is visibility-only — scenarios live in the spec artifacts the phases already load; the orchestrator does not thread them. Log alongside the profile/test-scope logs: `Scenario Depth: <depth>`.

8. **Emit session banner** — do this once, immediately after reading `ship/config.md` and resolving the phase set, and before any `▶ Fase:` log:

   **Determine the session tier**: inspect the system context to identify the model the current conversation is running on (e.g., `claude-haiku-*`, `claude-sonnet-*`, `claude-opus-*`). Normalize to one of `haiku`, `sonnet`, or `opus`.

   **Determine the phases tier**: the Ship model-routing policy (see # Model Routing Policy

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
```) runs quality phases (`perf`, `security`, `review`) on `sonnet` and the orchestrator itself on `haiku`. If `dev` is enabled, it runs on `sonnet`. Use `sonnet/haiku` as the phases tier label whenever both models are in use within the pipeline (which is the standard case); if all enabled phases use only one model tier, use that single label.

   **Read the Ship version**: parse the `version` field from `plugins/ship/package.json` (use the format `v<major>.<minor>`; if unavailable use `v2.x`).

   **Emit one of the two formats** (use `artifact_language` for surrounding prose, but keep model tier names in English):

   - **Override active** (session tier ≠ phases tier):
     ```
     ⬡ Ship v2.x | sessão=<session-tier> → fases=<phases-tier> | override ativo
     ```

   - **Same tier** (session tier matches the primary phases tier):
     ```
     ⬡ Ship v2.x | sessão=<session-tier> | fases no mesmo tier
     ```

   This banner is emitted exactly once per pipeline run. If the session model cannot be determined from context, default to displaying the banner in "same tier" format without the override suffix.

> **MANDATORY — LINEAR MODE: Set issue to "In Progress" before doing anything else**
>
> Call `mcp__linear-server__save_issue` to update the task issue status to **"In Progress"** right now.
> Do NOT continue to the development phase until this API call is confirmed.

**Local mode:**

Follow # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. for the Local mode artifact loading steps.

Additionally:
- Apply steps 5–6 above (effective phase set resolution and artifact_language extraction) — they are not Linear-specific.

> **From this point, all phase checks use the effective phase set built in step 5 — never raw `Pipeline Phases` alone.**

### 2. PHASE: Development

> **Phase check**: If `dev` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 3.

Invoke the `ship:develop` skill via the **Skill tool**. The skill declares `context: fork` + `model: "sonnet"` in its frontmatter, so Claude Code automatically runs it in an isolated subagent with full reasoning — do NOT wrap it in an `Agent` tool call. Pass the following context inline with the Skill invocation:

- Use the task description as the implementation spec (not the full feature — just THIS task)
- Read `ship/config.md` for project conventions
- Implement the code described in the task
- Run typecheck (if configured)
- Verify the change is under 400 lines: run `git diff --stat` and check
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

**Scratch dir:** `.context/ship-run/<task-id>/`

**The forked skill MUST use parallel sub-agents** for independent modules when applicable.

**Line count check**: After development, run `git diff --stat` to verify total lines changed. If it exceeds 400 lines:
- Warn the user: "This task produced ~X lines (target: <400). Consider splitting it."
- Do NOT block — this is a warning, not a gate.

### 3. PHASE: Testing

> **Phase check**: If `test` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 4.

Invoke the `ship:test` skill via the **Skill tool**. The skill declares `context: fork` + `model: "sonnet"` in its frontmatter, so it runs in an isolated subagent automatically — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Use the task's acceptance criteria to guide test generation
- Generate and run tests scoped to THIS task only
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

**The forked skill MUST launch 3 sub-agents in parallel**: unit tests, integration tests, e2e tests.

**Scratch dir:** `.context/ship-run/<task-id>/`

If any test fails after fix attempts:
- The pipeline STOPS. Inform the user.
- Ask if they want an automatic fix attempt.

### 4. PHASES: Quality Checks (PARALLEL)

> **Phase check**: Check each quality phase individually against the **effective phase set** (resolved in step 1.5):
> - If all three (`perf`, `security`, `review`) are `disabled`: skip this step entirely and proceed to Phase 5.
> - If some are `disabled`: launch only the agents for enabled phases. Skip the disabled ones.

> **Pre-quality snapshot:** The snapshot `.context/ship-run/<task-id>/pre-quality-snapshot.sha` was already captured in step 0.5. All quality agents and the PR agent can read the HEAD SHA from that file. See `ship/patterns/gates.md → Snapshot pré-fix` for format details and lifecycle rules.

**Read diff class** before launching agents:

```bash
DIFF_CLASS=$(cat .context/ship-run/<task-id>/diff-class.txt)
```

Apply the following adjustments **on top of** the effective phase set:

- **`trivial`**: Skip all quality phases (`perf`, `security`, `review`). Log: `Diff trivial — fases de qualidade puladas`. Append a PASS row for each skipped phase to `phase-status.md` with notes `diff trivial — pulado`. Proceed directly to Phase 5 (gate=PASS).
- **`minor`**: Skip `perf` and `review`. Launch only 1 combined security agent (covers all OWASP categories in a single pass). Log: `Diff minor — security combinado, perf/review pulados`. Append PASS rows for `perf` and `review` to `phase-status.md` with notes `diff minor — pulado`.
- **`normal`** or **`large`**: No adjustment — proceed with the standard agent setup below.

Invoke **up to 3 phase skills in parallel** via the **Skill tool** (one Skill call per enabled phase, dispatched in a SINGLE assistant turn so they fork concurrently). Each skill declares `context: fork` + `model: "sonnet"` in its own frontmatter, so each runs in an isolated subagent with full reasoning — do NOT wrap any of them in an `Agent` tool call. The orchestrator itself runs on Haiku per # Model Routing Policy

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

**Skill 1 — `ship:perf`** *(only if `perf` is `enabled`)*. Pass inline:
- Analyze the diff for this task only
- Write findings to a temporary file (local mode: `ship/changes/<feature>/perf-findings-<task-id>.md`)
- **Scratch dir:** `.context/ship-run/<task-id>/`
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

**Skill 2 — `ship:security`** *(only if `security` is `enabled`)*. Pass inline:
- Analyze the diff for this task only
- Write findings to a temporary file (local mode: `ship/changes/<feature>/security-findings-<task-id>.md`)
- **Scratch dir:** `.context/ship-run/<task-id>/`
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

**Skill 3 — `ship:review`** *(only if `review` is `enabled`)*. Pass inline:
- Analyze the diff for this task only
- Write findings to a temporary file (local mode: `ship/changes/<feature>/review-findings-<task-id>.md`)
- **Scratch dir:** `.context/ship-run/<task-id>/`
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

### 5. GATE CHECK

After all 3 agents complete, apply severity overrides before gate evaluation:

**Severity Overrides:**
Read `Severity Overrides` from `ship/config.md`. For each override rule (e.g., `high → warn`), downgrade matching findings from all phase reports before evaluating the gate. If the field is absent, no downgrade is applied.

Evaluate the gate decision manually based on the aggregated findings from all quality agents:
- **FAIL** — any critical or high finding remains after severity overrides
- **WARN** — no critical/high findings, but at least one medium finding remains
- **PASS** — only low/info findings, or no findings at all

**Before handling gate results:** Read the `Gate Behavior` section from `ship/config.md`:
- `on_fail`: controls behavior for exit code 2 (`ask` | `fix` | `defer`). Default: `ask`.
- `on_warn`: controls behavior for exit code 1 (`ask` | `fix` | `pass`). Default: `ask`.

**If exit code 2 (FAIL):**
1. Present the critical/high findings to the user
2. Create tracking issues:
   - **Linear mode:** Create sub-issues linked to the current task via `mcp__linear-server__save_issue` with rich descriptions (Context, What to do, Acceptance Criteria)
   - **Local mode:** Record in `ship/changes/<feature>/tracking.md`
3. Act based on `on_fail`:
   - **`ask`**: Ask "I found issues that need fixing. Would you like me to apply the fixes automatically?" — if yes, fix; if no, pause.
   - **`fix`**: Inform "Auto-fixing issues per project config..." and immediately launch an Agent to fix (**pass `model: "sonnet"` to the Agent tool call** — fixing is implementation reasoning), then apply the **Surgical Re-run Procedure** below using the set of phases that failed.
   - **`defer`**: Inform "Issues tracked for later (gate behavior: defer). Continuing pipeline..." and proceed to acceptance.

**If exit code 1 (WARN):**
1. Present warnings
2. Act based on `on_warn`:
   - **`ask`**: Ask "There are warnings. Fix now or proceed to acceptance?" — if fix, same flow as FAIL; if proceed, continue.
   - **`fix`**: Inform "Auto-fixing warnings per project config..." and apply fixes (**pass `model: "sonnet"` to the Agent tool call** — fixing is implementation reasoning), then apply the **Surgical Re-run Procedure** below using the set of phases that warned.
   - **`pass`**: Inform "Warnings noted (gate behavior: pass). Continuing to acceptance..." and proceed.

#### Surgical Re-run Procedure

> **Iteration limit**: Track a `$FIX_ITERATION` counter (starting at 1 for the first fix attempt). Before each fix attempt, check: if `$FIX_ITERATION > 3`, abort the pipeline immediately — inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária." Do NOT proceed to acceptance. Increment the counter after each fix.

> **Applies to both `on_fail: fix` and `on_warn: fix`**: both paths share this procedure and all edge cases below.

After the fix agent completes, determine which quality phases to re-run:

1. **Read `on_fail_rerun`** from `ship/config.md → Gate Behavior` (values: `surgical` | `all`, default: `surgical` if absent).

2. **Check if fix produced changes:**

   ```bash
   sha=$(cat .context/ship-run/<task-id>/pre-quality-snapshot.sha)
   git diff --name-only $sha HEAD
   ```

   If the output is **empty** (fix made no file changes):
   - Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
   - For each phase that failed/warned: append a row to `phase-status.md` with gate=`warn`, run=`#<N>`, timestamp=current ISO-8601, files=`-`, and notes=`fix sem mudanças — revisão manual necessária`.
   - Skip all re-run logic and continue to acceptance.

3. **If `on_fail_rerun: all`**: re-run all quality phases that were originally enabled (same set as Phase 4). Skip the scope mapping below.

4. **If `on_fail_rerun: surgical`** (default):

   a. The modified files list was already computed in step 2 above.

   b. **Check for out-of-scope files**: if ANY modified file does not match any phase scope rule (not under `src/**`, `lib/**`, or any path covered by the active phases), treat as "unknown area" and re-run ALL originally enabled quality phases in conservative mode:
      - Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
      - Launch all originally enabled quality phases in parallel (same setup as Phase 4).
      - Skip to step 4f (no further scope filtering needed).

   c. **Apply phase → scope mapping** for each phase that previously ran:

      | Phase | Scope |
      |-------|-------|
      | `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` |
      | `security` | All files in the diff (broad scope — always re-runs if it previously ran) |
      | `review` | All files in the original diff |
      | `analyze` | All files in the original diff (broad scope — always re-runs if it previously ran) |

   d. **For each phase that previously ran**: compute the intersection of (modified files from the fix) and (phase scope). If the intersection is non-empty → re-run. If empty → skip.

   e. **Log the decision** before launching agents:
      ```
      Fix tocou: <file1>, <file2> (<N> arquivo(s))
      Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
      Re-run pulado: <phase3> (não analisava arquivos modificados)
      ```

   f. **Re-invoke only the selected phase skills** via the **Skill tool** (in parallel if multiple, following the same Skill-invocation setup as Phase 4 — no `Agent` tool wrapper, since each phase skill forks itself via `context: fork`). Include `Artifact language: <artifact_language>` in each re-invocation, same as in Phase 4. Each re-invoked skill appends a new row to `phase-status.md` with run=`#<N>` (e.g., `#2` for first re-run) and notes=`re-run cirúrgico`.

5. **After re-run completes**: evaluate the gate decision again manually based on the new aggregated findings (same FAIL/WARN/PASS criteria as Phase 5). Handle the result using the same `on_fail`/`on_warn` logic — track `$FIX_ITERATION` to enforce the 3-iteration limit.

**If exit code 0 (PASS):**
Continue automatically.

### 6. PHASE: Analyze (Drift Detection)

> **Phase check**: If `analyze` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 7.

> **Invoke pattern**: This phase runs the `/ship:analyze` command. It orchestrates 2 agents in parallel then runs the correlation engine + report generation. If using `--analyze` flag on `ship run`, this phase is triggered automatically.

Invoke the `ship:analyze` skill via the **Skill tool**. The skill declares `context: fork` + `model: "sonnet"` in its frontmatter, so drift correlation (spec↔code↔tests) runs in an isolated subagent with full reasoning — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Use the task's spec (issue + Proposal + Design documents from Linear, or proposal.md + design.md in local mode)
- Use the code diff from `.context/ship-run/<task-id>/diff.md`
- Run spec extraction and code/test extraction **in parallel** (2 internal sub-agents)
- Pass results to the Correlation Engine
- Generate the drift report + compute gate
- Persist `drift-report.md` and `drift-findings.json` to scratch dir
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

**Scratch dir:** `.context/ship-run/<task-id>/`

**Mode-agnostic persistence:**
- **Linear mode:** Post `drift-findings.json` summary as a comment on the task issue via `mcp__linear-server__save_comment`
- **Local mode:** Export `drift-report.md` to `ship/changes/<feature>/drift-report.md`

**Monorepo support:** The agent detects which workspace is affected by inspecting diff paths. It filters spec requirements and test discovery to the detected workspace. If no workspace is detected, it analyzes the full repository.

**Gate behavior after ANALYZE:**
- Gate **FAIL** (critical/high findings) → act based on `on_fail` config (same flow as Phase 5)
- Gate **WARN** (medium findings) → act based on `on_warn` config (same flow as Phase 5)
- Gate **PASS** → continue to Phase 7

**Scope mapping for Surgical Re-run (if analyze phase fails/warns and needs re-run):**

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed) |

### 7. PHASE: User Acceptance

> **Phase check**: If `homolog` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 8.

Invoke the `ship:homolog` skill via the **Skill tool**. The skill declares `context: fork` in its frontmatter, so it runs in an isolated subagent automatically — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Consolidate findings into a quality report
- Present the report for this task
- Wait for user approval
- **Artifact language**: `<artifact_language>` — use this for all user-facing output (reports, summaries, gate results, status messages). Do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.`.

**Scratch dir:** `.context/ship-run/<task-id>/`

### 8. MANDATORY STOP — Await user confirmation for PR

After homolog approval:

1. **Verify Linear lifecycle completion** (quality report comment + "Done" status).

   **Linear mode:**

   > **MANDATORY — Verify the full Linear lifecycle was completed**
   >
   > The `/ship:homolog` phase should have already posted the quality report comment and set the issue to "Done".
   > In parallel: call `mcp__linear-server__get_issue_status` AND `mcp__linear-server__list_comments` to verify both:
   >
   > 1. If status is NOT "Done" → call `mcp__linear-server__save_issue` to set it to "Done" now.
   > 2. If the quality report comment is NOT present (i.e., no comment with a Summary table) → call `mcp__linear-server__save_comment` to post it now.
   >
   > Both the "Done" status AND the quality report comment are required before the task is considered complete.

   **Local mode:**
   - Write the consolidated report to `ship/changes/<feature>/report-<task-id>.md`
   - Mark the task as `done` in `tasks.md`

   **Both modes:** clean up temporary findings files.

2. Inform the user:
   - If working on multiple tasks: ask "Task '<name>' complete. Continue to the next task '<next-name>', or stop here?"
   - Otherwise: "**Task complete!** Run `/ship:pr` when ready to create a Pull Request."

3. **STOP HERE** — Do NOT invoke `/ship:pr` automatically.

4. Only proceed with PR creation when the user explicitly calls `/ship:pr`.

---

## Multi-task mode

When working on multiple tasks (`--project`, `--milestone`, or multiple IDs):

1. Sort tasks by **Linear milestone order** (deterministic field — never infer). Within a milestone, sort by issue creation date (also deterministic). Do NOT attempt dependency inference — the orchestrator runs on Haiku and that judgment call belongs to the user. If the user wants a different order, they pass explicit IDs in the desired sequence.
2. Process one task at a time through the full pipeline
3. After each task completion, ask the user before continuing
4. At the end, present a summary of all completed tasks

**Never process multiple tasks in parallel** — each task modifies code, so they must be sequential to avoid conflicts.

---

## Orchestrator Rules

- **1 task at a time by default**: Only work on multiple tasks if the user explicitly requests it.
- **Parallelism within phases is mandatory**: Quality checks ALWAYS run in parallel. Tests use 3 parallel agents.
- **Quality gates are non-negotiable for FAIL**: Critical/high findings MUST be resolved.
- **Line count awareness**: Warn (don't block) if a task exceeds 400 lines.
- **Respect pipeline phases**: Always build the **effective phase set** (step 1.5) before executing. Phases disabled by profile or explicit override MUST be skipped — inform the user: "Skipping [phase] (disabled in config)." and move to the next enabled phase.
- **Language**: Read `Artifact language` from `ship/config.md → Conventions` once in step 1.6 and inject the resolved value into every phase agent prompt. Phase SKILL.md files use this injected value and do not re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above.` during pipeline execution.
- **Shared scratch dir**: See # Run Context — Shared Scratch Between Agents

Temporary scratch pattern used by the `/ship:run` orchestrator to share context
between phase agents (develop, test, perf, security, review).

---

## Root directory

```
.context/ship-run/<task-id>/
```

`<task-id>` is the Linear issue identifier (e.g., `MOB-1140`) or, in local mode,
the feature slug (e.g., `my-feature`). The directory is ephemeral — never commit it
(see `.gitignore`).

> **`<task-id>` must contain only `[a-zA-Z0-9_-]`. Never use values containing `/`, `..`, or spaces.**

---

## Canonical files

| File | Written by | Read by | Content |
|------|-----------|---------|---------|
| `stack.md` | orchestrator (run) | all agents | detected stack summary — language, runtime, framework, test runner |
| `diff.md` | orchestrator (run) | perf, security, review | output of `git diff` for the branch — full diff of new/modified code |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `phase-status.md` | orchestrator (creates); agents (append) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `pre-quality-snapshot.sha` | orchestrator (run) | pr agent | HEAD commit SHA before quality phases — used to build the PR diff |
| `jaccard.json` | analyze agent | analyze agent (re-run) | Jaccard similarity matrix cache — keyed by diff + spec SHA-256 hashes; reused when hashes match to avoid redundant computation |

### `stack.md` format

```markdown
# Stack

- Language: TypeScript
- Runtime: Node.js 20+
- Framework: NestJS
- Test runner: vitest
- Package manager: npm
```

### `diff.md` format

Literal output of `git diff main...HEAD` (or the configured range), without truncation.

### `test-failures.md` format

Always written by the test agent — even if all tests passed (header-only = zero failures):

```markdown
# Test Failures

- src/auth/auth.service.ts (3 failures)
- src/users/users.repo.ts (1 failure)
```

When all tests pass, the file contains only the header:

```markdown
# Test Failures
```

Header-only (no bullet items) or absent file both indicate all tests passed.

### `phase-status.md` format

Each phase appends one row when it completes. Re-run iterations appear as additional rows with incremented run numbers. Timestamps are ISO-8601 UTC.

```markdown
# Phase Status

| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |
|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|
| develop | #1 | 2026-05-01T10:00:00Z | - | pass | 0 | 0 | 0 | 0 | |
| test | #1 | 2026-05-01T10:01:00Z | - | pass | 0 | 0 | 0 | 0 | |
| perf | #1 | 2026-05-01T10:02:00Z | src/runner.ts | warn | 0 | 0 | 2 | 1 | N+1 query detected |
| security | #1 | 2026-05-01T10:02:00Z | src/runner.ts, config.ts | pass | 0 | 0 | 0 | 0 | |
| review | #1 | 2026-05-01T10:02:00Z | src/runner.ts | pass | 0 | 0 | 0 | 0 | |
| perf | #2 | 2026-05-01T10:05:00Z | src/runner.ts | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### `pre-quality-snapshot.sha` format

Single-line file with the commit SHA:

```
a1b2c3d4e5f6...
```

### `jaccard.json` format

Written and read by the `analyze` agent (pipeline mode only). Invalidated whenever `diff_hash` or `spec_hash` changes.

```json
{
  "diff_hash": "<sha256 of diff.md content>",
  "spec_hash": "<sha256 of concatenated REQ-XX/AC-XX descriptions>",
  "matrix": {
    "REQ-01": { "code": ["src/foo.ts:10"], "score": 0.7 },
    "REQ-02": { "code": ["src/bar.ts:55"], "score": 0.3 },
    "AC-01":  { "tests": ["test/foo.test.ts:42"], "score": 0.9 },
    "AC-02":  { "tests": [], "score": 0.0 }
  }
}
```

- `diff_hash` and `spec_hash` are used as a compound cache key. If either changes, the entire matrix is recomputed.
- `matrix` maps each REQ-XX/AC-XX ID to its best-match file(s) and highest Jaccard score.
- `code` lists matched source file locations (`<path>:<line>`); `tests` lists matched test file locations.
- Absent file means the cache was computed in standalone mode (no scratch dir) — no `jaccard.json` is written in that case.

---

## Read/write conventions

- **Orchestrator** (`run.md`): sole owner of **creating** the directory and **writing**
  `stack.md`, `diff.md`, and `pre-quality-snapshot.sha` before launching any agent.
  Also creates `phase-status.md` with the empty header row at pipeline start.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files.
  The only write allowed is **appending** rows to `phase-status.md` upon phase completion.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files |
| During pipeline | Agents read and append as needed |
| End of `/ship:pr` | Orchestrator removes `.context/ship-run/<task-id>/` (recursive) |
| `--keep-context` flag in `/ship:pr` | Directory is preserved for manual inspection |

The parent directory `.context/ship-run/` may hold multiple `<task-id>/` subdirs if
parallel pipelines are running — never remove the parent, only the completed task's subdir.

---

## Inline context slicing (fan-out optimization)

When the orchestrator dispatches N parallel sub-agents, each agent opens a fresh conversation with no shared prompt cache. Passing large shared artifacts (diff, Design, proposal) to every agent multiplies token costs: **N × file size + N × cache miss**.

**Pattern:** the orchestrator reads each shared artifact **once**, slices it into per-agent subsets, and passes the slice **inline** in each agent's prompt. Agents must never re-read the original file.

### Slicing rules

- Always include enough surrounding context for the agent to understand scope:
  - For diffs: include the `diff --git a/...` file header + the full `@@ ... @@` hunk header + ±3 surrounding context lines for each included hunk.
  - For design/proposal docs: include the full subsection (heading + body) relevant to the agent's scope.
- If a hunk or section does not clearly belong to any agent's scope, include it in **all** agents' slices (conservative fallback).
- The orchestrator must not truncate content that agents need to make correct decisions — smaller is better, but correctness comes first.

### Which phases use this pattern

| Phase | Shared artifact sliced | Slice dimension |
|-------|------------------------|-----------------|
| `ship:security` | diff | by OWASP category (Injection / Auth / Data+Config) |
| `ship:test` | proposal ACs + file list | by test layer (unit / integration / e2e) |
| `ship:develop` | Design document | by module / independent implementation unit | for the `.context/ship-run/<task-id>/` structure and lifecycle.
- **Linear mode = zero local artifacts**: When Linear is configured, do NOT create `ship/changes/` directories. Task context comes from Linear, quality reports go as comments.
- **Local mode = full workspace**: When Linear is not configured, create all markdown artifacts locally.
- **Do not create the PR automatically**: The pipeline ends at acceptance. The user runs `/ship:pr` separately.
- **Each agent reads its command file**: This ensures each phase follows its own detailed instructions.
