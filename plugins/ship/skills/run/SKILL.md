---
name: ship:run
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
| `diff.md` | orchestrator (run) — baseline at init, refreshed after develop | perf, security, review | working-tree diff of the branch vs the merge-base (incl. untracked) — full diff of new/modified code |
| `plan.md` | plan skill (`ship:plan`) | develop, test | module map (disjoint file sets, dependencies, scenario→module) + test contract (scenario→layer→file slots) — the single source of truth both develop and test derive from. Absent when the planner is skipped — only for a `trivial`/`minor` *baseline* diff (a small change on top of pre-existing work); greenfield tasks always run the planner. |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `phase-status.md` | orchestrator (creates); agents (append) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `pre-quality-snapshot.sha` | orchestrator (run) | — | baseline HEAD SHA before quality phases (diagnostic; nothing commits mid-pipeline, so HEAD does not move and the PR diff is built from the working tree) |
| `pre-fix-files.txt` / `post-fix-files.txt` | orchestrator (run) | orchestrator (re-run) | per-file content snapshots (`<hash> <path>`) taken before/after the auto-fix Agent — diffed to scope the surgical re-run |
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

Literal, untruncated output of the branch's **working-tree** diff against the merge-base, including untracked files:

```bash
BASE=$(git merge-base origin/main HEAD)
git add -A -N   # surface untracked files; the scratch dir is gitignored and never added
git diff "$BASE"
```

The orchestrator writes it **twice**: a provisional baseline during init (step 0.5, before any code exists) and an authoritative refresh after `ship:develop` (step 2.5). The refresh is required because `ship:develop` writes code to the working tree without committing — an init-only, HEAD-based diff would be empty and the quality phases would analyze nothing. Standalone invocations (no scratch dir) fall back to `git diff origin/main...HEAD`, where the work under analysis is already committed.

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
  Also creates `phase-status.md` with the empty header row at pipeline start. The orchestrator
  **refreshes `diff.md` (and `diff-class.txt`) once more after the develop phase** — it is the
  only file rewritten mid-pipeline, and only by the orchestrator itself.
- **Planner** (`ship:plan`): sole writer of `plan.md`, before develop and test run. It is the
  one phase that produces (rather than only reads) a shared artifact other phases consume.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files
  (develop and test read `plan.md`).
  The only write allowed is **appending** rows to `phase-status.md` upon phase completion.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files (baseline `diff.md`) |
| After develop phase | Orchestrator refreshes `diff.md` + `diff-class.txt` over the post-develop working tree (authoritative) |
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
| `ship:test` | `plan.md` test contract (fallback: scenarios + file list) | by test layer (unit / integration / e2e) |
| `ship:develop` | `plan.md` module map (fallback: Design document) | by module / independent implementation unit | for canonical file formats and lifecycle rules.

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

2. **`diff.md`** (provisional baseline) — Capture the branch diff **relative to the merge-base, including the working tree and untracked files**, and write the full output (no truncation) to `.context/ship-run/<task-id>/diff.md`:

   ```bash
   BASE=$(git merge-base origin/main HEAD)
   git add -A -N   # surface new untracked files in the diff without staging content; the scratch dir is gitignored so it is never added
   git diff "$BASE"
   ```

   > This is the **pre-develop baseline** — it reflects only work that already existed before this run (re-runs, pre-committed work). It is consumed solely by the planner-gate classification in step 0.7. `ship:develop` integrates code into the working tree without committing, so the **authoritative** diff that the quality phases analyze is re-captured in step 2.5, after development.

3. **`phase-status.md`** — Create the file with only the header (no rows yet):

   ```markdown
   # Phase Status

   | Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |
   |-------|-----|-----------|-------|------|----------|------|--------|-----|-------|
   ```

   Write to `.context/ship-run/<task-id>/phase-status.md`.

3b. **`dispatch-log.md`** — Create the file with only the header (no rows yet):

   ```markdown
   # Dispatch Log

   | Phase | Tool | Name | Model | Timestamp |
   |-------|------|------|-------|-----------|
   ```

   Write to `.context/ship-run/<task-id>/dispatch-log.md`. The orchestrator appends one row to this file every time it dispatches a phase (see step 9, "Phase dispatch logging convention"). `homolog` reads it to render the `## Execution Trace` section.

4. **`pre-quality-snapshot.sha`** — Capture the current HEAD SHA and write it as a single line:

   ```bash
   git rev-parse HEAD
   ```

   Write the SHA to `.context/ship-run/<task-id>/pre-quality-snapshot.sha`.

5. **`pre-develop-files.txt`** — Capture a per-file content snapshot of the working tree **before development**, so the develop evidence gate (step 2.6) can prove whether `ship:develop` actually mutated anything. This is the **authoritative per-file content-snapshot idiom** reused by steps 2.6 and the Surgical Re-run Procedure (each writes to its own `<name>.txt` and diffs two snapshots with `comm -13`):

   ```bash
   BASE=$(git merge-base origin/main HEAD)
   git add -A -N   # surface untracked files; scratch dir is gitignored and never added
   git diff "$BASE" --name-only | while read -r f; do
     printf '%s %s\n' "$(git hash-object -- "$f" 2>/dev/null || echo absent)" "$f"
   done | sort > .context/ship-run/<task-id>/pre-develop-files.txt
   ```

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

> **This is the baseline classification** — it runs against the pre-develop `diff.md` and feeds only the planner-gate decision in step 1.9. The **authoritative** classification that drives the Phase 4 quality gate is recomputed in step 2.5 over the post-develop diff and overwrites `diff-class.txt`.

Run the deterministic classification exactly as specified in # Diff Classifier — Deterministic Heuristic

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
- `large` → `1 240 lines changed` (metric bash, sensitive-path parsing, top-down rules, output, and log format).

- **Inputs**: `.context/ship-run/<task-id>/diff.md` (the pre-develop baseline) and `ship/config.md` (`## Sensitive Paths` overrides).
- **Outputs**: write the class word to `.context/ship-run/<task-id>/diff-class.txt`, then log `Diff class (baseline): <class> (<reason>)` (note the `(baseline)` qualifier — the pattern's default log line omits it).

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

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`.`.

7. Read `Scenario Depth → depth` from `ship/config.md` (default `full` if the section is absent). This is visibility-only — scenarios live in the spec artifacts the phases already load; the orchestrator does not thread them. Log alongside the profile/test-scope logs: `Scenario Depth: <depth>`.

8. **Emit session banner** — do this once, immediately after reading `ship/config.md` and resolving the phase set, and before any `▶ Fase:` log:

   **Determine the session tier**: inspect the system context to identify the model the current conversation is running on (e.g., `claude-haiku-*`, `claude-sonnet-*`, `claude-opus-*`). Normalize to one of `haiku`, `sonnet`, or `opus`.

   **Determine the phases tier** from the Ship model-routing policy in # Model Routing Policy

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

3. **Reasoning units declare `model: "sonnet"` in frontmatter.** They never inherit from the
   parent session — Sonnet is pinned so behavior is identical standalone or via an orchestrator.
   Sonnet reasoning lives in the `plan`, `perf`, `security`, `review`, `analyze`, `spec` skills
   and all `audit:*` skills except `audit:run`; plus the leaf workers `ship-develop-implement`
   and `ship-test-{unit,integration,e2e}`. The `develop` and `test` **orchestrators are also Sonnet**:
   although `plan` front-loads the heavy decomposition, their bodies still make non-trivial judgment
   calls — slicing per-module/per-layer context, **de-identifying** it before injection, dependency
   ordering, integration checks — and must reliably dispatch rather than narrate. Per the Boundary
   rule (below), that keeps them at the reasoning tier rather than pinning Haiku. They still fan out
   Sonnet leaves for the actual code/test generation.

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
| `ship:homolog`        | haiku   | Report rendering + findings consolidation. **Not forked** — interactive acceptance gate; runs inline so approval and the Done transition share one context (see `ship:init`/`ship:pr`). |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:run`            | haiku (orchestrator) | Template/control-flow: file reads, deterministic diff classification, gate eval, dispatch. Spawns Sonnet agents explicitly for reasoning phases. |
| `ship:init`           | haiku (orchestrator) | Config-file template writing + interactive Q&A. Spawns Sonnet agents explicitly for stack/conventions detection. |
| `ship:audit:run` consolidation agent | haiku | Aggregates pre-structured audit reports |
| `ship:plan`           | sonnet   | Test-aware planning — decomposition + scenario→test mapping needs full reasoning |
| `ship:develop`        | sonnet (orchestrator) | Judgment dispatch: slices/de-identifies per-module context, fans out Sonnet `ship-develop-implement` leaves, integrates, typechecks. Kept at reasoning tier per the Boundary rule. |
| `ship:test`           | sonnet (orchestrator) | Judgment dispatch: resolves/de-identifies scenarios by layer, fans out Sonnet `ship-test-*` leaves. Kept at reasoning tier per the Boundary rule. |
| `ship-develop-implement`, `ship-test-{unit,integration,e2e}` | sonnet (leaf) | Code / test generation — needs full reasoning |
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
3. Sub-agents dispatched by an orchestrator run at the tier their own SKILL.md frontmatter
   declares, not the parent's — e.g. `run` (Haiku) dispatches `develop`/`test`, which run on Sonnet
   because their frontmatter declares `model: "sonnet"` (they are judgment orchestrators, not pure
   template phases — see the Boundary note). Pure template/aggregation sub-agents that declare or
   inherit Haiku stay on Haiku. Note: `homolog` is the exception among the Haiku phases — it is
   **not** forked (it is an interactive gate), so it runs inline in the caller's context rather than
   as a sub-agent.

**Boundary**: only apply this pattern when the orchestrator's body is genuinely deterministic.
If the orchestrator itself needs to make non-trivial judgment calls (e.g., dependency inference,
ambiguous classification, context de-identification, reliable act-not-narrate dispatch), do NOT
pin Haiku — either pin the reasoning tier (`model: "sonnet"`, as `develop`/`test` do) or rewrite
the judgment as a deterministic rule before downgrading. `ship:run` itself stays Haiku by taking
the latter route — see its multi-task note (dependency inference removed in favor of deterministic
Linear milestone order).

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

## How to verify routing at runtime

Self-attestation from inside the model context is **not reliable**: the model reads its identity from the system prompt's environment block, which is templated at session start and is not necessarily rewritten when the harness switches model mid-turn (e.g., when a skill's `model:` frontmatter takes effect). A model can be executing as Haiku and still report Opus because that is what the env block said when the session opened.

The ground truth lives in two places:

1. **`.context/ship-run/<task-id>/dispatch-log.md`** — the orchestrator's *intent*: which tool was called with which model parameter. Written by `ship:run` itself.

2. **Claude Code session JSONL** — what the harness *actually executed*. Every API response is logged with the real model ID. Path:
   ```
   ~/.claude/projects/<path-encoded>/<session-id>.jsonl
   ```
   Sub-agent transcripts live in `~/.claude/projects/<path-encoded>/<session-id>/subagents/agent-*.jsonl`.

   Quick audit of a session:
   ```bash
   jq -r '.message.model' <session-id>.jsonl | sort | uniq -c
   for f in <session-id>/subagents/agent-*.jsonl; do
     echo "== $(basename "$f") =="; jq -r '.message.model' "$f" | sort -u
   done
   ```

   If the orchestrator turns are split between session model and Haiku, the override is working. If they are 100% session model, routing failed.

A mismatch between dispatch-log and the JSONL is a routing bug. A mismatch between in-model self-attestation and the JSONL is **not** a routing bug — it is a known limitation of the env-block injection, and is why Ship no longer emits self-attestation banners.

---

## Pattern classification (skill-patterns-convention.md)

`model-routing.md` is a **bundle pattern** (> 30 lines). Reference in SKILL.md via:

```
For model routing rules, read the file at ./ship/patterns/model-routing.md completely.
```. Use `sonnet/haiku` as the phases tier label whenever both models are in use within the pipeline (the standard case); if all enabled phases use only one model tier, use that single label.

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

9. **Phase dispatch logging convention** — every time you dispatch a phase in steps 2–5 below (Development, Testing, Quality, Analyze), emit a single line to the terminal **AND** append the same data as a row to `.context/ship-run/<task-id>/dispatch-log.md`.

   Terminal format (one line, printed immediately before invoking the tool):

   ```
   ▶ Fase: <phase> | tool=<Skill|Agent> | name=<name> | model=<haiku|sonnet>
   ```

   `dispatch-log.md` row format:

   ```
   | <phase> | <Skill|Agent> | <name> | <haiku|sonnet> | <ISO-8601 UTC> |
   ```

   Field rules:
   - `<phase>`: one of `plan`, `dev`, `test`, `perf`, `security`, `review`, `analyze`.
   - `<tool>`: `Agent` when dispatching a named agent via `subagent_type` (e.g., `ship:ship-perf`); `Skill` when dispatching a forked skill via the Skill tool (e.g., `ship:test`, `ship:review`).
   - `<name>`: the `subagent_type` value (for Agent) or the skill name with `ship:` prefix (for Skill).
   - `<model>`: read from the dispatched worker's `model:` frontmatter. Named agents in `agents/` and skills in `skills/` both declare it.
   - For re-runs (Surgical Re-run Procedure), append a new row per re-dispatched phase — do not edit existing rows.
   - For skipped phases (diff-class adjustments, disabled in effective phase set): append a row with `tool=-`, `name=skipped`, `model=-` so the trace remains complete.

   **Language convention (applies to every phase dispatch below):** include the line `Artifact language: <artifact_language>` (resolved value from step 6) in each dispatched phase's inline context. Phase SKILL.md files use this injected value for all user-facing output and do NOT re-load `# Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`.`. The per-phase context blocks below show this line without repeating the rationale.

> **MANDATORY — LINEAR MODE: Move issue to its started state before doing anything else**
>
> Resolve the team's **started**-state name following this recipe — **do not pass the literal `"In Progress"`**, it silently no-ops on teams whose started state has another name (e.g., `Em andamento`):
>
> # Linear Status — resolve, set, and verify workflow-state transitions

> Canonical recipe for moving a task issue between workflow states.
> Used by `ship:run` / `ship:develop` (→ started) and `ship:homolog` / `ship:run` (→ completed).

A workflow-state **name** is team-configurable, so passing a hardcoded literal like `"In Progress"`
or `"Done"` to `save_issue` is unsafe: the `state` parameter is matched by state **name, type, or
ID**, and a team may have renamed it (e.g., `Em andamento`, `Concluído`, `Shipped`). When the name
does not match, the transition silently no-ops and the issue is left in its previous state.

Likewise, `get_issue_status` does **not** read an issue's current state — it requires
`id` + `name` + `team` and returns the definition of a status entity. To read the state an issue is
currently in, use `get_issue` and inspect its `state` field.

Linear workflow states each have a stable `type`. The two the pipeline transitions to are:

| Transition | Linear state `type` | Config field captured at `ship:init` | Default name |
|------------|---------------------|--------------------------------------|--------------|
| Start work | `started`           | `In Progress Status`                 | `In Progress` |
| Complete   | `completed`         | `Done Status`                        | `Done` |

---

## 1. Resolve the target state (do this once per transition)

1. Read the relevant config field (`In Progress Status` or `Done Status`) and `Team ID` from
   `ship/config.md → Linear Integration`.
2. If the field is present and not `not configured`, use it as the target state — it stores the
   team's real state name captured at `ship:init`.
3. If it is **absent** (older config) or `not configured`: call
   `mcp__linear-server__list_issue_statuses` with the `Team ID`, select the state whose `type`
   matches the transition (`started` or `completed`), and use its **name** as the target. If more
   than one state of that type exists, prefer the conventional name (`In Progress`/`Em andamento`
   for started; `Done`/`Concluído` for completed); otherwise take the first.

Call the resolved value `<target-state>`.

## 2. Set the state

Call `mcp__linear-server__save_issue` with:
- `id`: the task issue identifier (e.g., `MOB-1147`)
- `state`: `<target-state>`

## 3. Verify (never use `get_issue_status` for this)

Call `mcp__linear-server__get_issue` for the task issue and read its `state` field.
The transition succeeded when `state.type` matches the intended type (`started` or `completed`) —
a name-agnostic check.

If it does not match, the set failed — re-resolve `<target-state>` per step 1 (the configured name
may be stale), call `save_issue` again, and re-verify **once**. If it still fails, surface the issue
to the user with the resolved state name so they can fix the mapping in `ship/config.md` — do not
loop indefinitely.
>
> Then call `mcp__linear-server__save_issue` with `state: <target-state>` right now.
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

### 1.9. PHASE: Plan (Test-Aware Planning)

> **Phase check**: This phase runs when `dev` is `enabled` in the **effective phase set** AND the planner is warranted. Decide from the **baseline** classification (step 0.7), which measures only work that existed *before* this run:
> - **Baseline diff is empty** (greenfield — no pre-existing committed/uncommitted work): the implementation does not exist yet, so its size is unknown and a fresh task almost always warrants decomposition → **run the planner**. Detect with `[ -s .context/ship-run/<task-id>/diff.md ] || echo greenfield`.
> - **Baseline class `normal` or `large`**: → **run the planner**.
> - **Baseline class `trivial` or `minor`** (a small change on top of work that already exists): the decomposition is obvious → **skip** the planner; `ship:develop` will treat the task as a single module. Log when skipped: `Diff <class> (baseline) — planner pulado (módulo único)`. Append a skipped row to `dispatch-log.md` (`tool=-`, `name=skipped`, `model=-`).
>
> ⚠️ Do **not** skip the planner just because the baseline class is `trivial` on a greenfield branch — an empty baseline classifies as `trivial` (zero files) but means "nothing built yet", not "trivial change". The empty-diff check above takes precedence.

The planner does ONE interpretation of the `@SC-XX` scenarios and emits `.context/ship-run/<task-id>/plan.md` — a single source of truth that BOTH develop and test consume, so code and tests drift less at the source.

Invoke the `ship:plan` skill via the **Skill tool**. It declares `context: fork` + `model: "sonnet"` in its frontmatter, so the planning reasoning runs in an isolated Sonnet subagent automatically — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

```
Task: <task-id> — <title>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>

## Spec
<inline: issue description + ACs + @SC-XX scenarios>

## Design
<inline: full design document content>
```

**Scratch dir:** `.context/ship-run/<task-id>/`

### 2. PHASE: Development

> **Phase check**: If `dev` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 3.

Invoke the `ship:develop` skill via the **Skill tool**. It declares `context: fork` + `model: "sonnet"` in its frontmatter — an orchestrator that slices/de-identifies per-module context, fans out Sonnet `ship-develop-implement` workers, integrates, and typechecks, so do NOT wrap it in an `Agent` tool call. Pass the following context inline:

```
Task: <task-id> — <title>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>

## Spec
<inline: issue description + ACs>

## Design
<inline: full design document content>
```

**Scratch dir:** `.context/ship-run/<task-id>/` — `ship:develop` reads `plan.md` from here for the module map. If the planner was skipped (no `plan.md`), it implements the task as a single module.

**Line count check**: After development, run `git diff --stat` to verify total lines changed. If it exceeds 400 lines:
- Warn the user: "This task produced ~X lines (target: <400). Consider splitting it."
- Do NOT block — this is a warning, not a gate.

### 2.5. Refresh diff + classification (authoritative)

> **Why this step exists**: `ship:develop` integrates code into the **working tree** and does not commit. The baseline `diff.md` captured in step 0.5 therefore does **not** contain the implementation that develop just produced. Re-capture it here so the quality phases analyze real code. This refreshed `diff.md` and the recomputed `diff-class.txt` are the **authoritative** inputs for the diff-class quality gate and the `perf` / `security` / `review` phases in Phase 4.

> **Phase check**: Run this step only if the `dev` phase actually ran (it is `enabled` in the effective phase set). If `dev` was disabled, the baseline `diff.md` already reflects the diff under analysis — skip the refresh and keep the baseline classification.

1. **Re-capture `diff.md`** over the post-develop working tree (same range and command as step 0.5, now including the new and modified source files develop wrote):

   ```bash
   BASE=$(git merge-base origin/main HEAD)
   git add -A -N   # surface develop's new untracked files in the diff without staging content
   git diff "$BASE" > .context/ship-run/<task-id>/diff.md
   ```

2. **Re-run the deterministic classification** from step 0.7 against the refreshed `diff.md`, overwriting `.context/ship-run/<task-id>/diff-class.txt` with the new class. This is the value Phase 4 reads via `cat .context/ship-run/<task-id>/diff-class.txt`.

3. **Log to the user**:

   ```
   Diff reclassificado pós-develop: <class> (<reason>)
   ```

### 2.6. Develop evidence gate (MANDATORY)

> **Why this step exists**: `ship:develop` is a forked Haiku orchestrator with no Edit/Write tools — it produces code **only** by dispatching `ship-develop-implement` workers via the Agent tool. A known failure mode is the orchestrator *narrating* the plan and returning a success-looking status **without ever dispatching a worker**, leaving the working tree untouched. This gate does not trust develop's self-report: it independently proves, from the working tree itself, that real code was produced. Never accept a develop phase as `pass` on the orchestrator's word alone.

> **Phase check**: Run this gate only if the `dev` phase actually ran (it is `enabled` in the effective phase set). If `dev` was disabled, skip this gate entirely.

1. **Compute what develop actually changed** — run the content-snapshot idiom from step 0.5, writing to `post-develop-files.txt`, then diff it against the `pre-develop-files.txt` snapshot to list the files develop created or whose content changed this phase:

   ```bash
   comm -13 .context/ship-run/<task-id>/pre-develop-files.txt \
            .context/ship-run/<task-id>/post-develop-files.txt | awk '{print $2}' | sort -u
   ```

2. **Decide**:

   - **Non-empty** (develop mutated ≥1 file): evidence confirmed. Log `Develop evidence: <N> arquivo(s) modificado(s) ✓` and continue to Phase 3.

   - **Empty** (develop touched nothing this phase): distinguish a silent failure from a legitimate re-run by inspecting the **pre-develop** baseline `diff.md` (step 0.5):
     - **Baseline `diff.md` was non-empty** (work already existed before this run): treat as a legitimate "already implemented" re-run. Append a develop row to `phase-status.md` with gate=`warn` and notes=`develop sem mudanças — implementação pré-existente assumida`. Warn the user: `⚠ Develop não produziu mudanças; assumindo implementação pré-existente (re-run).` Continue.
     - **Baseline `diff.md` was empty** (fresh task, nothing existed): this is the silent-failure mode — develop returned without dispatching any worker. **The pipeline STOPS.** Append a develop row to `phase-status.md` with gate=`fail` and notes=`develop não produziu código — orquestrador não despachou workers`. Report to the user:
       ```
       ✗ FALHA no develop: a fase reportou conclusão mas o working tree não mudou.
         O orquestrador provavelmente narrou o plano sem despachar os workers de implementação.
         Pipeline interrompido. Re-execute o develop ou implemente manualmente.
       ```
       Do NOT proceed to testing or quality phases.

### 3. PHASE: Testing

> **Phase check**: If `test` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 4.

Invoke the `ship:test` skill via the **Skill tool**. The skill declares `context: fork` + `model: "sonnet"` in its frontmatter — an orchestrator that resolves/de-identifies scenarios by layer and fans out Sonnet `ship-test-*` leaf workers, so it runs in an isolated subagent automatically — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Use the task's acceptance criteria to guide test generation
- Generate and run tests scoped to THIS task only
- Artifact language: `<artifact_language>`

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

Apply the per-class adjustments **on top of** the effective phase set exactly as specified in # Diff Classifier — Deterministic Heuristic

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
- `large` → `1 240 lines changed` → "Behavior per Class" (which agents run, the log message, and the PASS rows to append to `phase-status.md`):

- **`trivial`**: all quality phases skipped → proceed directly to Phase 5 (gate=PASS).
- **`minor`**: only 1 combined security agent runs (`perf`/`review` skipped).
- **`normal`** or **`large`**: no adjustment — proceed with the standard agent setup below.

Invoke the quality phases in a SINGLE assistant turn so they run concurrently:
- **`perf`** (if enabled): dispatch via **Agent tool** with `subagent_type: ship:ship-perf` (named agent, runs with full Sonnet reasoning).
- **`security`** (if enabled): dispatch via **Agent tool** with `subagent_type: ship:ship-security` (named agent, runs with full Sonnet reasoning).
- **`review`** (if enabled): dispatch via **Skill tool** — declares `context: fork` + `model: "sonnet"` in its own frontmatter, so it runs in an isolated subagent automatically. Do NOT wrap it in an `Agent` tool call.

The orchestrator itself runs on Haiku per # Model Routing Policy

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

3. **Reasoning units declare `model: "sonnet"` in frontmatter.** They never inherit from the
   parent session — Sonnet is pinned so behavior is identical standalone or via an orchestrator.
   Sonnet reasoning lives in the `plan`, `perf`, `security`, `review`, `analyze`, `spec` skills
   and all `audit:*` skills except `audit:run`; plus the leaf workers `ship-develop-implement`
   and `ship-test-{unit,integration,e2e}`. The `develop` and `test` **orchestrators are also Sonnet**:
   although `plan` front-loads the heavy decomposition, their bodies still make non-trivial judgment
   calls — slicing per-module/per-layer context, **de-identifying** it before injection, dependency
   ordering, integration checks — and must reliably dispatch rather than narrate. Per the Boundary
   rule (below), that keeps them at the reasoning tier rather than pinning Haiku. They still fan out
   Sonnet leaves for the actual code/test generation.

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
| `ship:homolog`        | haiku   | Report rendering + findings consolidation. **Not forked** — interactive acceptance gate; runs inline so approval and the Done transition share one context (see `ship:init`/`ship:pr`). |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:run`            | haiku (orchestrator) | Template/control-flow: file reads, deterministic diff classification, gate eval, dispatch. Spawns Sonnet agents explicitly for reasoning phases. |
| `ship:init`           | haiku (orchestrator) | Config-file template writing + interactive Q&A. Spawns Sonnet agents explicitly for stack/conventions detection. |
| `ship:audit:run` consolidation agent | haiku | Aggregates pre-structured audit reports |
| `ship:plan`           | sonnet   | Test-aware planning — decomposition + scenario→test mapping needs full reasoning |
| `ship:develop`        | sonnet (orchestrator) | Judgment dispatch: slices/de-identifies per-module context, fans out Sonnet `ship-develop-implement` leaves, integrates, typechecks. Kept at reasoning tier per the Boundary rule. |
| `ship:test`           | sonnet (orchestrator) | Judgment dispatch: resolves/de-identifies scenarios by layer, fans out Sonnet `ship-test-*` leaves. Kept at reasoning tier per the Boundary rule. |
| `ship-develop-implement`, `ship-test-{unit,integration,e2e}` | sonnet (leaf) | Code / test generation — needs full reasoning |
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
3. Sub-agents dispatched by an orchestrator run at the tier their own SKILL.md frontmatter
   declares, not the parent's — e.g. `run` (Haiku) dispatches `develop`/`test`, which run on Sonnet
   because their frontmatter declares `model: "sonnet"` (they are judgment orchestrators, not pure
   template phases — see the Boundary note). Pure template/aggregation sub-agents that declare or
   inherit Haiku stay on Haiku. Note: `homolog` is the exception among the Haiku phases — it is
   **not** forked (it is an interactive gate), so it runs inline in the caller's context rather than
   as a sub-agent.

**Boundary**: only apply this pattern when the orchestrator's body is genuinely deterministic.
If the orchestrator itself needs to make non-trivial judgment calls (e.g., dependency inference,
ambiguous classification, context de-identification, reliable act-not-narrate dispatch), do NOT
pin Haiku — either pin the reasoning tier (`model: "sonnet"`, as `develop`/`test` do) or rewrite
the judgment as a deterministic rule before downgrading. `ship:run` itself stays Haiku by taking
the latter route — see its multi-task note (dependency inference removed in favor of deterministic
Linear milestone order).

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

## How to verify routing at runtime

Self-attestation from inside the model context is **not reliable**: the model reads its identity from the system prompt's environment block, which is templated at session start and is not necessarily rewritten when the harness switches model mid-turn (e.g., when a skill's `model:` frontmatter takes effect). A model can be executing as Haiku and still report Opus because that is what the env block said when the session opened.

The ground truth lives in two places:

1. **`.context/ship-run/<task-id>/dispatch-log.md`** — the orchestrator's *intent*: which tool was called with which model parameter. Written by `ship:run` itself.

2. **Claude Code session JSONL** — what the harness *actually executed*. Every API response is logged with the real model ID. Path:
   ```
   ~/.claude/projects/<path-encoded>/<session-id>.jsonl
   ```
   Sub-agent transcripts live in `~/.claude/projects/<path-encoded>/<session-id>/subagents/agent-*.jsonl`.

   Quick audit of a session:
   ```bash
   jq -r '.message.model' <session-id>.jsonl | sort | uniq -c
   for f in <session-id>/subagents/agent-*.jsonl; do
     echo "== $(basename "$f") =="; jq -r '.message.model' "$f" | sort -u
   done
   ```

   If the orchestrator turns are split between session model and Haiku, the override is working. If they are 100% session model, routing failed.

A mismatch between dispatch-log and the JSONL is a routing bug. A mismatch between in-model self-attestation and the JSONL is **not** a routing bug — it is a known limitation of the env-block injection, and is why Ship no longer emits self-attestation banners.

---

## Pattern classification (skill-patterns-convention.md)

`model-routing.md` is a **bundle pattern** (> 30 lines). Reference in SKILL.md via:

```
For model routing rules, read the file at ./ship/patterns/model-routing.md completely.
```.

**Phase 1 — `perf`** *(only if `perf` is `enabled`)*. Dispatch via **Agent tool** with `subagent_type: ship:ship-perf`. Pass all context inline:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Project Type: <project-type>
Stack: <stack>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content from .context/ship-run/<task-id>/diff.md>
```

**Phase 2 — `security`** *(only if `security` is `enabled`)*. Dispatch via **Agent tool** with `subagent_type: ship:ship-security`. Pass all context inline:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Stack: <stack>
Security Focus: <security-focus-category>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content from .context/ship-run/<task-id>/diff.md>
```

**Skill 3 — `ship:review`** *(only if `review` is `enabled`)*. Pass inline:
- Analyze the diff for this task only
- Write findings to `.context/ship-run/<task-id>/review-findings.md` (canonical scratch-dir path). In Linear mode, **do NOT** create `ship/changes/<feature>/` — the scratch dir is the only allowed write location.
- **Scratch dir:** `.context/ship-run/<task-id>/`
- Artifact language: `<artifact_language>`

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
   - **`fix`**: Inform "Auto-fixing issues per project config..."; **first capture the pre-fix snapshot** (Surgical Re-run Procedure → *Pre-fix snapshot* below), then launch an Agent to fix (**pass `model: "sonnet"` to the Agent tool call** — fixing is implementation reasoning), then apply the **Surgical Re-run Procedure** below using the set of phases that failed.
   - **`defer`**: Inform "Issues tracked for later (gate behavior: defer). Continuing pipeline..." and proceed to acceptance.

**If exit code 1 (WARN):**
1. Present warnings
2. Act based on `on_warn`:
   - **`ask`**: Ask "There are warnings. Fix now or proceed to acceptance?" — if fix, same flow as FAIL; if proceed, continue.
   - **`fix`**: Inform "Auto-fixing warnings per project config..."; **first capture the pre-fix snapshot** (Surgical Re-run Procedure → *Pre-fix snapshot* below), then apply fixes (**pass `model: "sonnet"` to the Agent tool call** — fixing is implementation reasoning), then apply the **Surgical Re-run Procedure** below using the set of phases that warned.
   - **`pass`**: Inform "Warnings noted (gate behavior: pass). Continuing to acceptance..." and proceed.

#### Surgical Re-run Procedure

> **Iteration limit**: Track a `$FIX_ITERATION` counter (starting at 1 for the first fix attempt). Before each fix attempt, check: if `$FIX_ITERATION > 3`, abort the pipeline immediately — inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária." Do NOT proceed to acceptance. Increment the counter after each fix.

> **Rationale, edge cases, and scope mapping** for this procedure live in # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. ("Snapshot pré-fix", "Re-run cirúrgico", "Re-run: edge cases") — including why working-tree snapshots are used instead of `git diff <sha> HEAD` (nothing commits mid-pipeline), the empty-fix and out-of-scope edge cases, and the `on_warn: fix` equivalence. This procedure applies to both `on_fail: fix` and `on_warn: fix`. The run-specific snapshot commands, output filenames, and iteration-counter mechanics below are authoritative.

**Pre-fix snapshot** — run the content-snapshot idiom from step 0.5, writing to `.context/ship-run/<task-id>/pre-fix-files.txt`. Capture it **immediately before launching the fix Agent** (the FAIL/WARN `fix` handler routes here first).

After the fix agent completes, determine which quality phases to re-run:

1. **Read `on_fail_rerun`** from `ship/config.md → Gate Behavior` (values: `surgical` | `all`, default: `surgical` if absent).

2. **Compute the set of files the fix changed** (snapshot diff — no commits involved). Run the content-snapshot idiom from step 0.5, writing to `post-fix-files.txt`, then list the entries new or content-changed since the pre-fix snapshot:

   ```bash
   comm -13 .context/ship-run/<task-id>/pre-fix-files.txt \
            .context/ship-run/<task-id>/post-fix-files.txt | awk '{print $2}' | sort -u
   ```

   If the resulting file list is **empty** (fix made no working-tree changes), apply # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. → "Re-run: edge cases" Edge case 1: log `⚠ Fix não produziu mudanças. Re-run ignorado.`, append a `warn` row (notes=`fix sem mudanças — revisão manual necessária`) to `phase-status.md` for each phase that failed/warned, then skip all re-run logic and continue to acceptance.

3. **If `on_fail_rerun: all`**: re-run all quality phases that were originally enabled (same set as Phase 4). Skip the scope mapping below.

4. **If `on_fail_rerun: surgical`** (default):

   a. The modified files list was already computed in step 2 above.

   b. **Check for out-of-scope files**: if ANY modified file matches no phase scope rule, follow # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. → Edge case 4 (conservative mode — re-run ALL originally enabled quality phases in parallel as in Phase 4, log the `Fix tocou arquivo(s) fora do scope original` line, and skip to step 4f).

   c. **Apply the phase → scope mapping** from # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. ("Re-run cirúrgico → Phase → scope mapping", plus the `analyze` row in its analyze-scope section) for each phase that previously ran.

   d. **For each phase that previously ran**: compute the intersection of (modified files from the fix) and (phase scope). If the intersection is non-empty → re-run. If empty → skip.

   e. **Log the decision** before launching agents, in the format defined in # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. ("Re-run cirúrgico → Log format": `Fix tocou:` / `Re-run cirúrgico:` / `Re-run pulado:`).

   f. **Re-invoke only the selected phases** using the same dispatch pattern as Phase 4 (in parallel if multiple): `perf` and `security` via **Agent tool** with their respective `subagent_type` (`ship-perf`, `ship-security`); `review` via **Skill tool** (declares `context: fork` in its own frontmatter). Include `Artifact language: <artifact_language>` in each re-invocation, same as in Phase 4. Each re-invoked phase appends a new row to `phase-status.md` with run=`#<N>` (e.g., `#2` for first re-run) and notes=`re-run cirúrgico`.

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
- Artifact language: `<artifact_language>`

**Scratch dir:** `.context/ship-run/<task-id>/`

**Mode-agnostic persistence:**
- **Linear mode:** Post `drift-findings.json` summary as a comment on the task issue via `mcp__linear-server__save_comment`
- **Local mode:** Export `drift-report.md` to `ship/changes/<feature>/drift-report.md`

**Monorepo support:** The agent detects which workspace is affected by inspecting diff paths. It filters spec requirements and test discovery to the detected workspace. If no workspace is detected, it analyzes the full repository.

**Gate behavior after ANALYZE:**
- Gate **FAIL** (critical/high findings) → act based on `on_fail` config (same flow as Phase 5)
- Gate **WARN** (medium findings) → act based on `on_warn` config (same flow as Phase 5)
- Gate **PASS** → continue to Phase 7

**Scope mapping for Surgical Re-run (if analyze phase fails/warns and needs re-run):** see # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. → "analyze phase scope mapping" — `analyze` has broad scope and re-runs whenever any file changed by the fix.

### 7. PHASE: User Acceptance

> **Phase check**: If `homolog` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 8.

Invoke the `ship:homolog` skill via the **Skill tool**. Unlike the other phases, homolog is **not** forked — it is an interactive acceptance gate that must run in this same context so it can present the report, stop for the user's approval, and then transition the issue. Do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Consolidate findings into a quality report
- Present the report for this task
- Wait for user approval
- Artifact language: `<artifact_language>`

**Scratch dir:** `.context/ship-run/<task-id>/`

> **MANDATORY STOP — Await user response if homolog asks a question**
>
> The `ship:homolog` skill ends by either (a) approving the task or (b) asking
> the user a question (e.g., "Quais ajustes precisam ser feitos?", "Algo a
> corrigir antes do PR?"). If the homolog output contains an open question
> directed at the user, the orchestrator MUST stop immediately and return
> control to the user — do NOT continue to Step 8, do NOT run additional
> verification, do NOT mark the task as complete.
>
> Only proceed to Step 8 when the user has explicitly approved (e.g.,
> "aprovado", "pode seguir", "ok PR", or equivalent in the artifact language).
> If the user requests adjustments, treat it as a fix iteration: apply the
> changes, then re-invoke `ship:homolog` for re-approval.

### 8. MANDATORY STOP — Await user confirmation for PR

After homolog approval:

1. **Verify Linear lifecycle completion** (quality report comment + "Done" status).

   **Linear mode:**

   > **MANDATORY — Verify the full Linear lifecycle was completed (idempotent safety-net)**
   >
   > The `/ship:homolog` phase should have already posted the quality report comment and transitioned the issue to its completed state. This step only repairs a miss.
   > First, resolve the team's **completed**-state name following this recipe — **never pass the literal `"Done"`**:
   >
   > # Linear Status — resolve, set, and verify workflow-state transitions

> Canonical recipe for moving a task issue between workflow states.
> Used by `ship:run` / `ship:develop` (→ started) and `ship:homolog` / `ship:run` (→ completed).

A workflow-state **name** is team-configurable, so passing a hardcoded literal like `"In Progress"`
or `"Done"` to `save_issue` is unsafe: the `state` parameter is matched by state **name, type, or
ID**, and a team may have renamed it (e.g., `Em andamento`, `Concluído`, `Shipped`). When the name
does not match, the transition silently no-ops and the issue is left in its previous state.

Likewise, `get_issue_status` does **not** read an issue's current state — it requires
`id` + `name` + `team` and returns the definition of a status entity. To read the state an issue is
currently in, use `get_issue` and inspect its `state` field.

Linear workflow states each have a stable `type`. The two the pipeline transitions to are:

| Transition | Linear state `type` | Config field captured at `ship:init` | Default name |
|------------|---------------------|--------------------------------------|--------------|
| Start work | `started`           | `In Progress Status`                 | `In Progress` |
| Complete   | `completed`         | `Done Status`                        | `Done` |

---

## 1. Resolve the target state (do this once per transition)

1. Read the relevant config field (`In Progress Status` or `Done Status`) and `Team ID` from
   `ship/config.md → Linear Integration`.
2. If the field is present and not `not configured`, use it as the target state — it stores the
   team's real state name captured at `ship:init`.
3. If it is **absent** (older config) or `not configured`: call
   `mcp__linear-server__list_issue_statuses` with the `Team ID`, select the state whose `type`
   matches the transition (`started` or `completed`), and use its **name** as the target. If more
   than one state of that type exists, prefer the conventional name (`In Progress`/`Em andamento`
   for started; `Done`/`Concluído` for completed); otherwise take the first.

Call the resolved value `<target-state>`.

## 2. Set the state

Call `mcp__linear-server__save_issue` with:
- `id`: the task issue identifier (e.g., `MOB-1147`)
- `state`: `<target-state>`

## 3. Verify (never use `get_issue_status` for this)

Call `mcp__linear-server__get_issue` for the task issue and read its `state` field.
The transition succeeded when `state.type` matches the intended type (`started` or `completed`) —
a name-agnostic check.

If it does not match, the set failed — re-resolve `<target-state>` per step 1 (the configured name
may be stale), call `save_issue` again, and re-verify **once**. If it still fails, surface the issue
to the user with the resolved state name so they can fix the mapping in `ship/config.md` — do not
loop indefinitely.
   > In parallel: call `mcp__linear-server__get_issue` (read its `state`) AND `mcp__linear-server__list_comments` to verify both:
   >
   > 1. If `state.type != "completed"` → call `mcp__linear-server__save_issue` with `state: <completed-state>` now.
   > 2. If the quality report comment is NOT present (i.e., no comment with a Summary table) → call `mcp__linear-server__save_comment` to post it now.
   >
   > Both the completed state AND the quality report comment are required before the task is considered complete. Do NOT use `get_issue_status` to read the issue's state.

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

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`.` during pipeline execution.
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
| `diff.md` | orchestrator (run) — baseline at init, refreshed after develop | perf, security, review | working-tree diff of the branch vs the merge-base (incl. untracked) — full diff of new/modified code |
| `plan.md` | plan skill (`ship:plan`) | develop, test | module map (disjoint file sets, dependencies, scenario→module) + test contract (scenario→layer→file slots) — the single source of truth both develop and test derive from. Absent when the planner is skipped — only for a `trivial`/`minor` *baseline* diff (a small change on top of pre-existing work); greenfield tasks always run the planner. |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `phase-status.md` | orchestrator (creates); agents (append) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `pre-quality-snapshot.sha` | orchestrator (run) | — | baseline HEAD SHA before quality phases (diagnostic; nothing commits mid-pipeline, so HEAD does not move and the PR diff is built from the working tree) |
| `pre-fix-files.txt` / `post-fix-files.txt` | orchestrator (run) | orchestrator (re-run) | per-file content snapshots (`<hash> <path>`) taken before/after the auto-fix Agent — diffed to scope the surgical re-run |
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

Literal, untruncated output of the branch's **working-tree** diff against the merge-base, including untracked files:

```bash
BASE=$(git merge-base origin/main HEAD)
git add -A -N   # surface untracked files; the scratch dir is gitignored and never added
git diff "$BASE"
```

The orchestrator writes it **twice**: a provisional baseline during init (step 0.5, before any code exists) and an authoritative refresh after `ship:develop` (step 2.5). The refresh is required because `ship:develop` writes code to the working tree without committing — an init-only, HEAD-based diff would be empty and the quality phases would analyze nothing. Standalone invocations (no scratch dir) fall back to `git diff origin/main...HEAD`, where the work under analysis is already committed.

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
  Also creates `phase-status.md` with the empty header row at pipeline start. The orchestrator
  **refreshes `diff.md` (and `diff-class.txt`) once more after the develop phase** — it is the
  only file rewritten mid-pipeline, and only by the orchestrator itself.
- **Planner** (`ship:plan`): sole writer of `plan.md`, before develop and test run. It is the
  one phase that produces (rather than only reads) a shared artifact other phases consume.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files
  (develop and test read `plan.md`).
  The only write allowed is **appending** rows to `phase-status.md` upon phase completion.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files (baseline `diff.md`) |
| After develop phase | Orchestrator refreshes `diff.md` + `diff-class.txt` over the post-develop working tree (authoritative) |
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
| `ship:test` | `plan.md` test contract (fallback: scenarios + file list) | by test layer (unit / integration / e2e) |
| `ship:develop` | `plan.md` module map (fallback: Design document) | by module / independent implementation unit | for the `.context/ship-run/<task-id>/` structure and lifecycle.
- **Linear mode = zero local artifacts**: When Linear is configured, do NOT create `ship/changes/` directories. Task context comes from Linear, quality reports go as comments.
- **Local mode = full workspace**: When Linear is not configured, create all markdown artifacts locally.
- **Do not create the PR automatically**: The pipeline ends at acceptance. The user runs `/ship:pr` separately.
- **Each agent reads its command file**: This ensures each phase follows its own detailed instructions.
