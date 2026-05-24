---
name: audit:database
description: "Ship Audit: project-wide database audit. Routes to MongoDB, PostgreSQL, or MySQL methodology based on ship/config.md. 3 parallel agents."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

<!-- IMPL-REQ-01: file contains no references to src/audits/database/, databaseAuditModule, TypeScript modules, or ship binary -->
<!-- IMPL-REQ-02: 32 heuristics embedded — MongoDB 15 (A:5, B:5, C:5), PostgreSQL 10 (A:4, B:3, C:3), MySQL 7 (A:3, B:2, C:2) -->
<!-- IMPL-REQ-03: 3-agent parallel structure via Agent tool — single call per DB path -->
<!-- IMPL-REQ-04: gate logic delegates to # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

Before launching the parallel quality phases (perf / security / review), the orchestrator captures a snapshot of the current HEAD commit. This snapshot is used by the PR agent to build the diff and, when auto-fix is applied, to decide which phases to re-run.

**When it is captured:** step 0.5 of `run.md` — during scratch-dir initialization, before any quality agent starts.

**File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`

**Format:** single line containing the SHA from `git rev-parse HEAD` (no trailing newline required).

**When it is read:**
- By the PR agent (`pr.md`) to build the diff between the snapshot and the final HEAD.
- By the orchestrator after auto-fix to determine which phases to re-run (controlled by `on_fail_rerun`).

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

1. Read `pre-quality-snapshot.sha` from scratch dir
2. Run `git diff --name-only <sha> HEAD` to get modified files from the fix
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

**Trigger:** `git diff --name-only <sha> HEAD` returns empty after the fix agent runs.

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

**Trigger:** After the fix, `git diff --name-only` returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. — Critical/High→FAIL, Medium→WARN, Low→PASS -->
<!-- IMPL-REQ-05: output covers Linear mode (linear-audit-template.md) and Local mode (ship/audits/database-<date>.md) -->

# Ship Audit — Database

Conduct a project-wide audit of the database layer. Read `ship/config.md` to determine the database type and route to the appropriate methodology.

## Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

## Process

### 1. Load context

See # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input.. Read `ship/config.md` per # Stack Detection

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

### 2. Route to methodology

| Database | Methodology |
|---|---|
| `MongoDB` | MongoDB path (3 agents) |
| `PostgreSQL` | PostgreSQL path (3 agents) |
| `MySQL` | MySQL path (3 agents) |
| `SQLite` | PostgreSQL path, adapt recommendations |
| `none` / not set | Warn: update Database field and re-run. Stop. |
| Unknown | PostgreSQL path; note assumption in report |

### 3. Launch 3 agents in parallel

Use the **Agent** tool — **3 agents in a SINGLE call**.

---

## MongoDB Path

### Agent A — Write Operations + Data Modeling (heuristics 1–5)

#### Heuristic 1 — write-concern (**Critical**)
**What to look for:** `w: 0` or `writeConcern: { w: 0 }` — fire-and-forget writes.
**Detection pattern:** 1. Search all connection/query files for `w: 0` or `writeConcern.*w.*0`. 2. Flag every match.
**Severity:** Critical
**Remediation:** Change to `w: 1` or `w: "majority"` for critical data.

#### Heuristic 2 — bson-limit (High)
**What to look for:** Sub-document arrays or `Schema.Types.Mixed` arrays without `maxlength`.
**Detection pattern:** 1. Find `[{ ... }]` or `Schema.Types.Mixed` in Mongoose schemas. 2. Check 5 lines for `maxlength`; flag if absent.
**Severity:** High
**Remediation:** Move large nested arrays to a separate collection; add `maxlength` validators.

#### Heuristic 3 — unbounded-array (Medium)
**What to look for:** `[String]`, `[Number]`, `[ObjectId]` array fields without `maxlength`.
**Detection pattern:** 1. Find those patterns in schema/model files. 2. Check 5 lines for `maxlength`; flag if absent.
**Severity:** Medium
**Remediation:** Add `maxlength` to prevent 16MB BSON limit risk.

#### Heuristic 4 — push-without-slice (Medium)
**What to look for:** `$push` without `$slice`.
**Detection pattern:** 1. Find `$push` in query files. 2. Check surrounding 15 lines for `$slice`; flag if absent.
**Severity:** Medium
**Remediation:** Use `{ $push: { field: { $each: [value], $slice: -N } } }`.

#### Heuristic 5 — upsert-no-unique-index (High)
**What to look for:** `updateOne`/`findOneAndUpdate`/`replaceOne` with `upsert: true` and no unique index on filter field.
**Detection pattern:** 1. Find `upsert: true`. 2. Check 10 lines for `unique: true`; flag if absent.
**Severity:** High
**Remediation:** Add `unique: true` on filter fields; handle `E11000` in code.

---

### Agent B — Index Analysis (heuristics 6–10)

#### Heuristic 6 — collection-scan (High)
**What to look for:** `.find({})` empty filter OR `.aggregate()` without `$match` as first stage.
**Detection pattern:** 1. Find `.find({})`. 2. Find `.aggregate(`; check first stage — flag if not `$match`.
**Severity:** High
**Remediation:** Always filter in `.find()`; put `$match` first in every pipeline.

#### Heuristic 7 — missing-index (High)
**What to look for:** `.find({...})`, `.findOne({...})`, `.findMany({...})` with non-empty filter and no `.hint()`.
**Detection pattern:** 1. Find those calls with non-empty query objects. 2. Check 20 lines for `.hint(`; flag if absent.
**Severity:** High
**Remediation:** Add compound index on filter fields; use `.hint(indexName)` for critical paths.

#### Heuristic 8 — lookup-missing-index (High)
**What to look for:** `$lookup` where `foreignField` has no index in the target collection.
**Detection pattern:** 1. Find `$lookup` with `foreignField`. 2. Check file for `createIndex`/`ensureIndex` on that field; flag if absent.
**Severity:** High
**Remediation:** Index `foreignField` in target collection; prevents O(n²) join.

#### Heuristic 9 — fulltext-no-text-index (High)
**What to look for:** `$text` or `$search` operators without a text index.
**Detection pattern:** 1. Find `$text:` or `$search:` in queries. 2. Check schema files for `type: 'text'`; flag if absent.
**Severity:** High
**Remediation:** Create `{ field: 'text' }` index in schema or via `createIndex()`.

#### Heuristic 10 — in-large (Medium)
**What to look for:** `$in` with inline array > 80 chars or variable reference.
**Detection pattern:** 1. Find `$in: [` where content > 80 chars. 2. Find `$in:` followed by variable name; flag both.
**Severity:** Medium
**Remediation:** Batch the list; cap size before query; reconsider data model.

---

### Agent C — Queries + Configuration (heuristics 11–15)

#### Heuristic 11 — regex-unanchored (Medium)
**What to look for:** `$regex` pattern not starting with `^`.
**Detection pattern:** 1. Find `$regex:` or inline regex in queries. 2. Flag patterns without `^` prefix.
**Severity:** Medium
**Remediation:** Prefix with `^` for index use; use `$text` for mid-string searches.

#### Heuristic 12 — slow-query (Medium)
**What to look for:** `.find()`, `.findOne()`, `.aggregate()` without `.maxTimeMS()`.
**Detection pattern:** 1. Find those calls. 2. Check 10 lines for `.maxTimeMS(` or `maxTimeMS:`; flag if absent.
**Severity:** Medium
**Remediation:** Chain `.maxTimeMS(5000)` to prevent runaway queries.

#### Heuristic 13 — connection-pool (Medium)
**What to look for:** `mongoose.connect()` or `MongoClient()` without `maxPoolSize`.
**Detection pattern:** 1. Find those calls. 2. Check 15 lines for `maxPoolSize`; flag if absent.
**Severity:** Medium
**Remediation:** Set `maxPoolSize` based on CPU count and concurrency requirements.

#### Heuristic 14 — oplog-retention (Low)
**What to look for:** Replica set connection without `oplogSizeMB`.
**Detection pattern:** 1. Find connections with replica set indicators. 2. Check config files for `oplogSizeMB` or `--oplogSize`; flag if absent.
**Severity:** Low
**Remediation:** Set `storage.wiredTiger.engineConfig.oplogSizeMB` in `mongod.conf`.

#### Heuristic 15 — wiredtiger-cache (Low)
**What to look for:** MongoDB connection without `wiredTigerCacheSizeGB`.
**Detection pattern:** 1. Find connection setup. 2. Check config/env for `wiredTigerCacheSizeGB` or `cacheSizeGB`; flag if absent.
**Severity:** Low
**Remediation:** Set `storage.wiredTiger.engineConfig.cacheSizeGB`; default may be suboptimal in containers.

---

## PostgreSQL Path

### Agent A — Schema + Write Operations (heuristics 1–4)

#### Heuristic 1 — sequential-scan (High)
**What to look for:** `SELECT *` without `LIMIT`.
**Detection pattern:** 1. Find `SELECT *` in SQL strings and ORM calls. 2. Check same line + next 3 for `LIMIT`; flag if absent.
**Severity:** High
**Remediation:** Use explicit columns; add `LIMIT`; verify with `EXPLAIN (ANALYZE, BUFFERS)`.

#### Heuristic 2 — missing-index (High)
**What to look for:** `.query()` or `.execute()` with SELECT+WHERE and no index hint comment.
**Detection pattern:** 1. Find those calls with SELECT+WHERE in next 5 lines. 2. Check for `-- idx:` comment; flag if absent.
**Severity:** High
**Remediation:** Add `CREATE INDEX ON table (column)`; verify with `EXPLAIN (ANALYZE, BUFFERS)`.

#### Heuristic 3 — for-update-no-timeout (High)
**What to look for:** `FOR UPDATE` without preceding `lock_timeout` or `statement_timeout`.
**Detection pattern:** 1. Find `FOR UPDATE`. 2. Check 20 lines before for `lock_timeout`/`statement_timeout`; flag if absent.
**Severity:** High
**Remediation:** Set `SET lock_timeout = '5s'`; use `NOWAIT` or `SKIP LOCKED`.

#### Heuristic 4 — autovacuum (High)
**What to look for:** `autovacuum = off` or `autovacuum_vacuum_scale_factor > 0.5`.
**Detection pattern:** 1. Find `autovacuum = off`; flag immediately. 2. Find `autovacuum_vacuum_scale_factor`; flag if > 0.5.
**Severity:** High
**Remediation:** Keep autovacuum on; set scale factor to 0.01 for large tables.

---

### Agent B — Index + JSON Types (heuristics 5–7)

#### Heuristic 5 — json-vs-jsonb (Medium)
**What to look for:** `JSON` column (not `JSONB`) in DDL.
**Detection pattern:** 1. Find ` JSON ` or ` JSON NOT NULL` in CREATE/ALTER TABLE. 2. Exclude `JSONB`; flag the rest.
**Severity:** Medium
**Remediation:** Migrate to `JSONB`; supports GIN indexes, faster access.

#### Heuristic 6 — transaction-wrap (Medium)
**What to look for:** 2+ DML queries in same block without explicit transaction.
**Detection pattern:** 1. Scan 15-line windows for 2+ `.query()` with INSERT/UPDATE/DELETE. 2. Check ±5 lines for `BEGIN`/`COMMIT`; flag if absent.
**Severity:** Medium
**Remediation:** Wrap related DML in `BEGIN`/`COMMIT`.

#### Heuristic 7 — trigger-large-table (Medium)
**What to look for:** `CREATE TRIGGER` without `WHEN` condition.
**Detection pattern:** 1. Find `CREATE TRIGGER` / `CREATE OR REPLACE TRIGGER`. 2. Check next 10 lines for `WHEN`; flag if absent.
**Severity:** Medium
**Remediation:** Add `WHEN` condition to limit trigger to changed rows.

---

### Agent C — Configuration + Constraints (heuristics 8–10)

#### Heuristic 8 — connection-pool (Medium)
**What to look for:** `new Pool()` or `createPool()` without `max`, or `max > 100`.
**Detection pattern:** 1. Find pool creation. 2. Check next 5 lines for `max`; flag if absent or > 100.
**Severity:** Medium
**Remediation:** Set `max` based on `max_connections` and app instance count.

#### Heuristic 9 — deferrable-constraint (Low)
**What to look for:** `FOREIGN KEY` without `DEFERRABLE`.
**Detection pattern:** 1. Find `FOREIGN KEY`. 2. Check same + next 2 lines for `DEFERRABLE`; flag if absent.
**Severity:** Low
**Remediation:** Add `DEFERRABLE INITIALLY DEFERRED`.

#### Heuristic 10 — text-no-length (Low)
**What to look for:** `TEXT` column in `CREATE TABLE` without length constraint.
**Detection pattern:** 1. Scan 30-line CREATE TABLE blocks. 2. Flag `TEXT` columns with no length bound.
**Severity:** Low
**Remediation:** Use `VARCHAR(255)` for bounded fields.

---

## MySQL Path

### Agent A — Schema + Engine (heuristics 1–3)

#### Heuristic 1 — myisam-engine (High)
**What to look for:** `ENGINE = MyISAM` in DDL.
**Detection pattern:** 1. Search DDL/migration files for `ENGINE.*MyISAM` (case-insensitive). 2. Flag every match.
**Severity:** High
**Remediation:** Migrate to `ENGINE=InnoDB`; MyISAM lacks transactions, FK, row-level locking.

#### Heuristic 2 — utf8-charset (High)
**What to look for:** `CHARSET = utf8` or `CHARACTER SET utf8` (not `utf8mb4`).
**Detection pattern:** 1. Find `CHARSET.*utf8` or `CHARACTER SET.*utf8`. 2. Exclude `utf8mb4`; flag the rest.
**Severity:** High
**Remediation:** Migrate to `utf8mb4`; MySQL `utf8` only supports 3-byte characters.

#### Heuristic 3 — missing-index (High)
**What to look for:** SELECT+WHERE with no `USE INDEX` or `FORCE INDEX` hint.
**Detection pattern:** 1. Find `.query()`/`.execute()` with SELECT+WHERE. 2. Check ±5 lines for `USE INDEX`/`FORCE INDEX`; flag if absent.
**Severity:** High
**Remediation:** Add indexes; verify with `EXPLAIN`.

---

### Agent B — Configuration (heuristics 4–5)

#### Heuristic 4 — innodb-buffer-pool (Medium)
**What to look for:** `innodb_buffer_pool_size` below 128MB.
**Detection pattern:** 1. Find `innodb_buffer_pool_size = <value>` in config files. 2. Parse value (M/MB/G/GB); flag if < 128MB.
**Severity:** Medium
**Remediation:** Set to 70–80% of RAM; < 128MB causes excessive disk I/O.

#### Heuristic 5 — query-cache (Medium)
**What to look for:** `query_cache_type` enabled or `query_cache_size` non-zero.
**Detection pattern:** 1. Find `query_cache_type = [1-9]` or `= ON`. 2. Find `query_cache_size = [1-9]`; flag both.
**Severity:** Medium
**Remediation:** Set `query_cache_type=0`, `query_cache_size=0`; removed in MySQL 8.0.

---

### Agent C — Constraints + Schema (heuristics 6–7)

#### Heuristic 6 — foreign-key-missing (Medium)
**What to look for:** `_id INT` column in `CREATE TABLE` without `FOREIGN KEY`.
**Detection pattern:** 1. Find CREATE TABLE blocks (30 lines). 2. Find `(\w+_id) INT` without `FOREIGN KEY` in same block; flag each.
**Severity:** Medium
**Remediation:** Add `FOREIGN KEY (column) REFERENCES table(id)`.

#### Heuristic 7 — varchar-excessive-length (Low)
**What to look for:** `VARCHAR(N)` where N > 1000.
**Detection pattern:** 1. Find all `VARCHAR(N)` in DDL. 2. Parse N; flag if > 1000.
**Severity:** Low
**Remediation:** Use realistic max (255 email, 500 URL); oversized lengths waste temp table memory.

---

## 4. Consolidate findings

Each agent produces findings per # Ship — Report Templates

Canonical source for all reporting templates used across Ship command files.
Import by reference: `See ship/report-templates.md#<anchor>`.

---

## Finding Entry {#finding-entry}

Base template. All domains share this structure.

```markdown
### [SEVERITY] <Descriptive Title>
- **Category:** <domain-specific — see extensions below>
- **File:** <path>:<line>
- **Description:** <what the problem is>
- **Impact:** <estimated impact>
- **Suggestion:** <specific fix with code example if helpful>
```

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md).

### Domain extensions

Fields that **replace or add to** the base template per domain:

**Performance pipeline** (`perf.md`) — categories: `DB | ALGO | MEM | NET | BUNDLE | RENDER | ARCH`
> No extra fields. Uses base template as-is.

**Security pipeline** (`security.md`) — categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639 Authorization Bypass Through User-Controlled Key>  # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker would gain>                            # keeps (same field, specific guidance)
- **Proof of Concept:** <example malicious request/payload when applicable>  # adds
- **Fix:** <specific code change with example>                         # replaces Suggestion
```

**Code Review pipeline** (`review.md`) — categories: `SOLID-S | SOLID-O | SOLID-L | SOLID-I | SOLID-D | DRY | KISS | CLEAN | CONSISTENCY | TEST`
```markdown
- **Principle:** <SOLID-* | DRY | KISS | CLEAN | CONSISTENCY | TEST>  # replaces Category
- **Problem:** <what's wrong and why it matters>                      # replaces Description
```

**Frontend audit** (`audit/frontend.md`) — categories: `NET | BUNDLE | LOAD | RENDER | JS | HYDRAT | IMG | FONT | MEM | 3P | ARCH`
(Next.js: `STRATEGY | BOUNDARY | CACHE | BUNDLE | STREAMING | IMG | FONT | MIDDLEWARE | BUILD | COLD | ARCH`)
```markdown
- **Metric affected:** LCP | INP | CLS | FCP | TTFB | TBT | First Load JS | Bundle size  # adds
- **Effort:** <Hours | Days | Weeks>                                   # adds
```

**Backend audit** (`audit/backend.md`) — categories: `DB | NET | CPU | MEM | CONC | CODE | CONF | ARCH`
```markdown
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Maintenance window:** <Yes | No>                                   # adds
```

**Security audit** (`audit/security.md`) — categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC | DEPS | PRIV`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639>                                            # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker or data breach would yield>            # keeps
- **Proof of Concept:** <example malicious request/payload for critical/high findings>  # adds
- **Fix:** <specific code change with example using the project's patterns>  # replaces Suggestion
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Urgent deploy:** <Yes | No>                                        # adds
```

**Database audit** (`audit/database.md`) — categories: `MDL | IDX | QRY | WRT | CFG | SCH | PERF`
```markdown
- **Collection/Table:** <name(s) affected>                             # adds (before File)
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Requires migration:** <Yes | No>                                   # adds
```

---

## Finding JSON Schema {#finding-schema}

Base schema. Applies to all domains.

```json
{
  "severity": "critical|high|medium|low",
  "category": "<domain-specific>",
  "filePath": "src/path/to/file.ts",
  "line": 42,
  "title": "...",
  "description": "...",
  "suggestion": "..."
}
```

### Schema extensions by domain

**Security pipeline / Security audit** — additional fields:
```json
{
  "owasp": "A03:2021 Injection",
  "cwe": "CWE-89"
}
```

**Frontend audit** — additional fields:
```json
{
  "metricAffected": "LCP|INP|CLS|FCP|TTFB|TBT|First Load JS|Bundle size",
  "effort": "Hours|Days|Weeks"
}
```

**Backend audit** — additional fields:
```json
{
  "effort": "Hours|Days|Weeks",
  "maintenanceWindow": true
}
```

**Database audit** — additional fields:
```json
{
  "collectionOrTable": "<name>",
  "effort": "Hours|Days|Weeks",
  "requiresMigration": true
}
```

---

## Drift Analysis Findings {#drift-findings}

Used by `/ship:analyze` phase. Extends the base Finding Entry with drift-specific fields.

### Finding Entry Format

| Field | Type | Description |
|-------|------|-------------|
| Severity | critical \| high \| medium \| low | See severity.md — Drift domain |
| Category | IMPL \| TEST \| SCENARIO \| DRIFT | IMPL = implementation gap, TEST = AC test coverage gap, SCENARIO = scenario coverage gap, DRIFT = low-confidence match |
| File | path or — | Source file where the issue was detected |
| Description | string | What is missing or mismatched |
| Suggestion | string | How to fix: implement the req, add a test, or add an override marker |
| Requirement ID | REQ-XX or — | Linked requirement, if applicable |
| Criterion ID | AC-XX or — | Linked acceptance criterion, if applicable |
| Scenario ID | SC-XX or — | Linked scenario, if applicable |
| Layer | unit \| integration \| e2e or — | Scenario's tagged test layer (SCENARIO findings only) |

### Severity Mapping

| Severity | Trigger | Gate Impact |
|----------|---------|-------------|
| critical | Requirement with 0 code matches | FAIL |
| high | Requirement confidence < 0.5 | FAIL |
| medium | Acceptance criterion with 0 test matches | WARN |
| medium | Scenario with 0 test matches in its tagged enabled layer | WARN |
| low | Criterion or scenario confidence < 0.5 | PASS |

### Example Reports

#### PASS
`✓ Análise de Drift: PASS (0 gaps) — [ver relatório completo](link)`

#### WARN (medium findings)
```
### [MEDIUM] Critério sem cobertura de teste: AC-03
- **Categoria:** TEST
- **Descrição:** O critério de aceitação "AC-03" não possui testes identificados.
- **Sugestão:** Crie um teste para o critério AC-03 ou adicione o marcador TEST-AC-03.
```

#### FAIL (critical findings)
```
### [CRITICAL] Requisito não implementado: REQ-05
- **Categoria:** IMPL
- **Descrição:** O requisito "REQ-05: Cache invalidation" não possui implementação identificada.
- **Sugestão:** Implemente o requisito REQ-05 ou adicione o marcador IMPL-REQ-05 no arquivo.
```

### JSON Schema

```json
{
  "severity": "critical | high | medium | low",
  "category": "IMPL | TEST | DRIFT",
  "title": "string",
  "description": "string",
  "suggestion": "string",
  "requirementId": "REQ-XX | null",
  "criterionId": "AC-XX | null",
  "filePath": "string | null",
  "line": "number | null"
}
```

---

## Quality Report {#quality-report}

Consolidated from `homolog.md`. Used in both Linear mode (as issue comment) and Local mode (as `report-<task-id>.md`).

Each findings section is rendered using the lazy-load algorithm — see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`.

```markdown
# Quality Report — <Feature / Task Title>

## Summary
| Phase | Gate | Critical | High | Medium | Low |
|-------|------|----------|------|--------|-----|
| Performance | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Security | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Code Review | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |

## Performance Findings
<!-- gate = PASS: one-line summary only -->
✓ Performance: PASS (0 critical/high findings) — [see full report](<link or path>)

<!-- gate = WARN or FAIL: critical/high/medium in full; low aggregated -->
### [HIGH] <Title>
<finding in Finding Entry format>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ 3 low-severity findings — [see full report](<link or path>)

## Security Findings
<!-- same lazy-load pattern as Performance -->

## Code Review Findings
<!-- same lazy-load pattern as Performance -->

## Fixes Applied
<list of fixes applied automatically during the pipeline, or "None.">

## Homologation
- [ ] User has reviewed all changes
- [ ] User has verified acceptance criteria
- [ ] User approves for PR
```

---

## Acceptance Report {#acceptance-report}

Consolidated from `homolog.md`. Presented to the user during the acceptance phase.

```markdown
## Acceptance Report — <Feature / Task Title>

### What was implemented
<3-5 bullet points summarizing what was built>

### Technical decisions
<Key decisions from the Design document>

### Tests
- Unit tests: X created, all passing
- Integration tests: Y created, all passing
- E2E tests: Z created (or "not applicable")

### Quality Gates
| Phase | Status | Details |
|-------|--------|---------|
| Performance | PASS / WARN / FAIL | X findings |
| Security | PASS / WARN / FAIL | X findings |
| Code Review | PASS / WARN / FAIL | X findings |

### Pending warnings
<Medium-level findings accepted by the user, or "None.">

### Acceptance criteria — Manual verification
<From the issue/proposal — for the user to check off>
- [ ] Criterion 1
- [ ] Criterion 2
```

---

## PR Body Template {#pr-body}

Extracted from `pr.md`. Used by `/ship:pr` to build the pull request description via `gh pr create`.

```markdown
## Summary
<From Proposal: why this change was made — 2-3 sentences>

## Changes
<From Design: architecture overview + key technical decisions>

### Files Changed
<From Design: files created and modified>

## Test Results
| Type | Count | Status |
|------|-------|--------|
| Unit | <n> | Passing |
| Integration | <n> | Passing |
| E2E | <n> | Passing / N/A |

## Quality Report
<!-- lazy-load algorithm: see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md` -->

### Summary
| Phase | Gate | Critical | High | Medium | Low |
|-------|------|----------|------|--------|-----|
| Performance | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Security | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Code Review | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |

### Performance Findings
<!-- gate = PASS: one-line summary only -->
✓ Performance: PASS (0 critical/high findings) — [see full report](<link or path>)

<!-- gate = WARN or FAIL: critical/high/medium in full; low aggregated -->

### Security Findings
<!-- same lazy-load pattern as Performance -->

### Code Review Findings
<!-- same lazy-load pattern as Performance -->

## Test Plan
<From acceptance criteria — for PR reviewer to verify>
- [ ] Criterion 1
- [ ] Criterion 2

---
Generated by **Ship** | Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Lazy Mode {#lazy-mode}

Canonical rendering format for per-phase findings in quality reports and PR descriptions.
For the decision algorithm (how to determine PASS / WARN / FAIL), see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`.

### Gate = PASS — tabela-resumo

When a phase gate = PASS, emit only the compact summary table row. **No findings content is embedded.**

Format:

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

Single-phase inline variant (used inside phase subsections):

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

**Example — all phases PASS:**

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

### Gate = WARN or FAIL — bloco expandido

When a phase gate = WARN or FAIL, embed findings inline. Apply the filter:
- **Include in full**: all findings with severity `critical`, `high`, or `medium`
- **Aggregate**: replace all `low` findings with a single count line

Format:

```
### [HIGH] <Title>
<finding in Finding Entry format — see #finding-entry>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ N low-severity findings — [see full report](<link or path>)
```

**Example — Security gate = FAIL:**

### [HIGH] SQL Injection in search endpoint
- **Category:** INJ
- **File:** src/routes/search.ts:34
- **Description:** User input is interpolated directly into a raw SQL query without parameterization.
- **Impact:** Full database read/write access for an attacker.
- **Suggestion:** Use parameterized queries via the ORM or prepared statements.

### [MEDIUM] Missing rate limiting on login route
- **Category:** CFG
- **File:** src/routes/auth.ts:12
- **Description:** The POST /login endpoint has no rate limit, enabling brute-force attacks.
- **Impact:** Credential enumeration and account takeover.
- **Suggestion:** Apply a rate-limiting middleware (e.g., express-rate-limit) with a 5-attempts/minute threshold.

+ 3 low-severity findings — [see full report](https://linear.app/mobitech/issue/MOB-XXXX)

---

## Report Summary Table {#report-summary}

Compact summary block used at the end of `/ship:perf`, `/ship:security`, `/ship:review`, and all `/ship:audit:*` reports.

```markdown
## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**
```#finding-entry, extended with:
- **Collection/Table:** `<affected>` *(before **File**)*
- **Effort:** `<Hours | Days | Weeks>`
- **Requires migration:** `<Yes | No>`

Category values: `MDL | IDX | QRY | WRT | CFG | SCH | PERF`
See # Severity Definitions

## Performance

- **critical**: Will cause visible performance degradation in production (e.g., N+1 on every request, full table scan on large table)
- **high**: Likely to cause issues under load (e.g., missing pagination on growing dataset)
- **medium**: Suboptimal but will not cause immediate issues (e.g., missing cache on moderately accessed data)
- **low**: Best practice not followed, marginal impact (e.g., synchronous logging in low-traffic endpoint)

## Security

- **critical**: Remote exploitation without authentication, unrestricted access to sensitive data. Requires immediate fix.
- **high**: Exploitation possible with authentication or specific conditions. Significant impact risk.
- **medium**: Hard to exploit but relevant impact, or easy to exploit with limited impact.
- **low**: Theoretical risk, defense-in-depth, or best practice not followed.

## Code Review

- **critical**: Architectural issue that will cause significant problems if not addressed (e.g., circular dependency, broken abstraction that leaks implementation details across the entire system)
- **high**: Significant design issue that will make the code hard to maintain/extend (e.g., god class, tight coupling between modules)
- **medium**: Code smell that should be addressed but does not block (e.g., duplicated logic, overly complex conditional)
- **low**: Minor improvement opportunity (e.g., naming could be clearer, slightly long function)

## Frontend

Uses Core Web Vitals thresholds:

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| LCP | ≤ 2.5s | 2.5s – 4.0s | > 4.0s |
| INP | ≤ 200ms | 200ms – 500ms | > 500ms |
| CLS | ≤ 0.1 | 0.1 – 0.25 | > 0.25 |
| FCP | ≤ 1.8s | 1.8s – 3.0s | > 3.0s |
| TTFB | ≤ 800ms | 800ms – 1800ms | > 1800ms |

- **critical**: Core Web Vital in "Poor" range; severely impacting UX or conversion
- **high**: Core Web Vital in "Needs Improvement"; measurable impact on bounce/conversion
- **medium**: Relevant technical inefficiency, no immediate critical impact
- **low**: Incremental optimization, good for backlog

## Database

- **critical**: Causes active production degradation, data risk, or imminent failure as data grows
- **high**: Significant performance degradation that worsens with data growth
- **medium**: Relevant inefficiency, no immediate critical impact
- **low**: Best practice not followed, marginal impact

## Drift (Spec ↔ Code ↔ Test conformance)

| Severity | Definition | Examples |
|----------|-----------|---------|
| critical | Requirement has zero code matches (confidence = 0) — completely unimplemented | REQ-05 not found anywhere in diff |
| high | Requirement has low confidence match (0 < confidence < 0.5) — implementation uncertain | REQ-03 found in loosely related file, confidence 0.2 |
| medium | Acceptance criterion has zero test matches — criterion not tested | AC-07 not covered by any test |
| medium | Scenario has zero test matches in its tagged enabled layer — scenario not tested | SC-09 (@integration) not covered by any test |
| low | Acceptance criterion has low confidence test match — coverage uncertain | AC-12 mentioned in unrelated test, confidence 0.1 |
| low | Scenario has low confidence test match — coverage uncertain | SC-04 loosely matched, confidence 0.2 |

### Override Markers

To assert known-correct coverage and bypass keyword matching:
- `IMPL-REQ-XX` in source code → forces requirement confidence to 1.0 (implemented)
- `IMPL-SC-XX` in source code → hint that a scenario's behavior lives in divergently-named code (does not by itself prove a test exists)
- `TEST-REQ-XX` / `TEST-AC-XX` in test file → forces criterion confidence to 1.0 (tested); grants child scenarios 0.8 partial credit
- `TEST-SC-XX` in test file → forces scenario `SC-XX` confidence to 1.0 (tested)

Use override markers when requirement names don't match code naming conventions (e.g., spec says "cache invalidation" but code uses "eviction").

## Severity Overrides

Before applying standard gate rules (`critical|high → fail`, `medium → warn`), check if `ship/config.md` contains a `## Severity Overrides` section. If present, apply matching overrides before evaluating the gate.

### Format

```
## Severity Overrides
- <phase>: <from-severity>→<to-severity>
```

Where `<phase>` must be one of the valid pipeline phases: `dev`, `test`, `perf`, `security`, `review`, `frontend-perf`, `database`, `backend`.

### How to apply

1. Read all entries under `## Severity Overrides` in `ship/config.md`.
2. For each finding in the current phase, check if an override matches (`phase` + `from-severity`).
3. If matched, replace the finding's effective severity with `to-severity` before the gate decision.
4. Apply standard gate rules to the (possibly overridden) effective severities.

### Validation

If an override entry references an unknown phase (not in the valid phase list above), emit an error and stop:

```
Severity override refers to unknown phase: <phase-name>
```

Do not silently ignore unknown phase overrides — fail fast to prevent misconfiguration.

### Examples

**Example 1 — Downgrade perf high to warn**

Config:
```
## Severity Overrides
- perf: high→warn
```

Effect: A `high` finding in the `perf` phase becomes effective severity `warn` (medium gate level). Gate decision: WARN instead of FAIL.

**Example 2 — Downgrade frontend-perf high to warn**

Config:
```
## Severity Overrides
- frontend-perf: high→warn
```

Effect: LCP "Needs Improvement" findings (`high`) in the `frontend-perf` phase generate a WARN gate instead of FAIL. Security, review, and other phases are unaffected.

**Example 3 — Multiple overrides**

Config:
```
## Severity Overrides
- perf: high→warn
- security: medium→low
```

Effect: `high` perf findings → WARN gate; `medium` security findings → treated as `low` (PASS if no other critical/high). Each phase applies only its own override. (## Database).

## 5. Write report

**Local mode:** `ship/audits/database-<YYYY-MM-DD>.md`

**Linear mode:** Follow # Ship — Linear Audit Template

Canonical pattern for creating Linear artifacts after an audit run.
Import by reference: `See ship/linear-audit-template.md`.

Used by: `audit/backend.md`, `audit/frontend.md`, `audit/security.md`, `audit/database.md`.

---

## When to use

Apply this template in **Linear mode** (i.e., `ship/config.md → Linear Integration: yes`) after completing an audit analysis and generating a report.

In **Local mode**, write the report to `ship/audits/<type>-<YYYY-MM-DD>.md` instead.

---

## Step 1 — Create Linear project

Call `mcp__linear-server__save_project` with:

- **Name**: `<Audit Type> — <YYYY-MM-DD>` (e.g., "Backend Performance Audit — 2026-04-29")
- **Team**: from `ship/config.md → Linear Integration → Team ID`
- **Description** (varies by audit type — see [Category variations](#category-variations)):
  - Project/app name (from `ship/config.md → Project → Name`)
  - Stack context (runtime, framework, database or framework methodology)
  - Gate result and findings count (e.g., "2 critical, 3 high, 1 medium")
  - One-sentence summary of the most critical/impactful issue found

> **Never search for or reuse an existing project** — not even one that looks related. Each audit run gets its own dedicated project.

---

## Step 2 — Create report document

Call `mcp__linear-server__save_document` with:

- **Title**: `<Audit Type> — <YYYY-MM-DD>`
- **Project**: the project created in Step 1
- **Content**: the full audit report in markdown

---

## Step 3 — Create milestones per severity

Call `mcp__linear-server__save_milestone` for each severity level that has at least one finding. Skip milestones with zero findings.

| Condition | Milestone name |
|-----------|---------------|
| Any `critical` findings | "Critical Fixes" |
| Any `high` findings | "High Fixes" |
| Any `medium` findings | "Medium Fixes" |
| Any `low` findings | "Low Fixes" |

For each milestone:
- **Team**: from `ship/config.md → Linear Integration → Team ID`
- **Project**: the project created in Step 1

---

## Step 4 — Create issues per finding

For each finding at any severity (critical, high, medium, low), call `mcp__linear-server__save_issue` with:

- **Title**: `[PREFIX] <finding title>` — see [Category variations](#category-variations) for the prefix
- **Team**: from `ship/config.md → Linear Integration → Team ID`
- **Project**: the project created in Step 1
- **Priority**: Urgent (critical) / High (high) / Medium (medium) / Low (low)
- **Labels**: primary label (or closest available in the team) + `severity` label — see [Category variations](#category-variations)
- **Milestone**: link to the corresponding milestone from Step 3
- **Description**: use the base template below, extended with category-specific fields

### Base issue description template

```markdown
## Problem
<What the problem is, with concrete evidence from the code. Cite file and line.>

## Impact
<Estimated impact — latency, memory, security risk, data integrity. Include projection at 10x data if relevant.>

## Evidence
- **File:** <path>:<line>
- **Code:** <relevant snippet showing the issue>

## Fix
<Specific fix with a code example in the project's language and framework.>

## Acceptance Criteria
- [ ] <Specific, verifiable criterion>
- [ ] <Another verifiable criterion>
- [ ] No regressions in related tests

## Notes
- **Effort:** <Hours | Days | Weeks>
```

---

## Category variations {#category-variations}

Each audit type customizes the project description, issue prefix, labels, and adds extra fields to the issue description template.

### Backend Performance (`audit/backend.md`)

- **Project description**: includes runtime, framework, database
- **Issue prefix**: `[PERF]`
- **Labels**: `performance`
- **Extra fields** (append to `## Notes`):
  ```markdown
  - **Maintenance window required:** <Yes | No>
  ```

### Frontend Performance (`audit/frontend.md`)

- **Project description**: includes framework and methodology (e.g., "Next.js App Router — 5-layer methodology")
- **Issue prefix**: `[PERF]`
- **Labels**: `performance`
- **Replaces `## Impact` guidance with**:
  ```markdown
  ## Impact
  <Estimated impact on user-perceived performance — which Web Vital is affected, estimated degradation.>
  ```
- **Extra fields** (append to `## Notes`):
  ```markdown
  - **Affected Web Vital:** <LCP | CLS | INP | TTFB | FCP | TBT>
  ```

### Security (`audit/security.md`)

- **Project description**: includes runtime, framework, database and overall A–F score
- **Issue prefix**: `[SEC]`
- **Labels**: `security`
- **Replaces base template** with:
  ```markdown
  ## Vulnerability
  <What the vulnerability is, with concrete evidence. Cite file and line. Include OWASP category and CWE.>

  ## Attack Vector
  <How this could be exploited — step-by-step. Who can trigger it (unauthenticated / authenticated).>

  ## Impact
  <What an attacker or a data breach would yield. Data exposed, accounts compromised, system access gained.>

  ## Proof of Concept
  <For critical/high: example malicious request, payload, or exploit flow demonstrating the vulnerability.>

  ## Fix
  <Specific code change with example using the project's patterns.>

  ## Acceptance Criteria
  - [ ] <Specific, verifiable criterion — e.g., "input is validated server-side before being used in query">
  - [ ] <Another verifiable criterion>
  - [ ] Security-related tests pass
  - [ ] No regressions in related tests

  ## Notes
  - **Effort:** <Hours | Days | Weeks>
  - **Urgent deploy required:** <Yes | No>
  ```

### Database (`audit/database.md`)

- **Project description**: includes database engine and version (MongoDB / PostgreSQL / MySQL)
- **Issue prefix**: `[DB]`
- **Labels**: `performance`
- **Extra fields** (replace `## Evidence` guidance and append to `## Notes`):
  ```markdown
  ## Evidence
  - **File:** <path>:<line>
  - **Query/Schema:** <relevant snippet — query, schema definition, or index declaration>

  ## Notes
  - **Effort:** <Hours | Days | Weeks>
  - **Maintenance window required:** <Yes | No>
  ```

### Tests Coverage (`audit/tests.md`)

- **Project description**: includes Test Scope layers enabled/disabled (unit, integration, e2e), total AC count, gate result (PASS / WARN), and one-sentence summary of the most critical coverage gap
- **Issue prefix**: `[TEST]`
- **Labels**: `test-coverage`
- **Replaces `## Evidence` and appends extra fields to `## Notes`**:
  ```markdown
  ## Evidence
  - **AC / REQ:** <AC-XX or REQ-XX>
  - **Layer:** unit | integration | e2e
  - **Current confidence:** <0.0 to 1.0>
  - **Closest test match:** <file>:<test name> (Jaccard: <score>) | none

  ## Fix
  <Example test snippet that would cover this AC>

  ## Notes
  - **Layer:** unit | integration | e2e
  - **Current confidence:** <0.0 to 1.0>
  - **Effort:** <Hours | Days>
  ``` — prefix `[DB]`, label `performance`. Evidence: file:line + snippet. Extra note: `Maintenance window required: <Yes | No>`.

**Report format:**
```markdown
# Database Audit — <YYYY-MM-DD>
Database: <MongoDB | PostgreSQL | MySQL>

## Summary
- Critical: X | High: X | Medium: X | Low: X | **Gate: PASS | WARN | FAIL**

## General Diagnosis
<5-line executive summary>

## Index Analysis by Collection/Table
[indexes: existing, add, remove]

## Findings
[ordered by severity — critical first]

## Prioritized Roadmap
| Priority | Finding | Category | Est. Impact | Effort | Quick win? |

## Validation Metrics
| Finding | Metric | Current | Target |

## Best Practices Checklist
[DB-specific checklist]

## Blind Spots
| Hypothesis | Why unconfirmed | How to validate |
```

Gate rules: See # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

Before launching the parallel quality phases (perf / security / review), the orchestrator captures a snapshot of the current HEAD commit. This snapshot is used by the PR agent to build the diff and, when auto-fix is applied, to decide which phases to re-run.

**When it is captured:** step 0.5 of `run.md` — during scratch-dir initialization, before any quality agent starts.

**File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`

**Format:** single line containing the SHA from `git rev-parse HEAD` (no trailing newline required).

**When it is read:**
- By the PR agent (`pr.md`) to build the diff between the snapshot and the final HEAD.
- By the orchestrator after auto-fix to determine which phases to re-run (controlled by `on_fail_rerun`).

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

1. Read `pre-quality-snapshot.sha` from scratch dir
2. Run `git diff --name-only <sha> HEAD` to get modified files from the fix
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

**Trigger:** `git diff --name-only <sha> HEAD` returns empty after the fix agent runs.

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

**Trigger:** After the fix, `git diff --name-only` returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. — Critical/High → FAIL, Medium → WARN, Low → PASS.

### Return JSON summary

After writing the report, output the following JSON block as the **very last content** of your tool result. `ship:audit:run` reads this directly from the agent result — no file re-read needed.

See # Audit Summary Schema

Each `ship:audit:*` agent must output this JSON block as the **very last content** of its tool result. `ship:audit:run` reads it directly from the agent result (already in context) — no file I/O needed.

## Schema

```json
{
  "audit": "<backend|frontend|database|security|tests>",
  "gate": "<PASS|WARN|FAIL>",
  "score": "<A|B|C|D|F>",
  "counts": {
    "critical": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "top_findings": [
    {
      "id": "<FINDING-ID>",
      "severity": "<critical|high|medium|low>",
      "title": "<short title>",
      "file": "<path/to/file.ts:line>"
    }
  ],
  "report_path": "ship/audits/<type>-<YYYY-MM-DD>.md"
}
```

## Field definitions

| Field | Type | Description |
|-------|------|-------------|
| `audit` | string | Audit type identifier |
| `gate` | `PASS\|WARN\|FAIL` | Gate result per `# Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

Before launching the parallel quality phases (perf / security / review), the orchestrator captures a snapshot of the current HEAD commit. This snapshot is used by the PR agent to build the diff and, when auto-fix is applied, to decide which phases to re-run.

**When it is captured:** step 0.5 of `run.md` — during scratch-dir initialization, before any quality agent starts.

**File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`

**Format:** single line containing the SHA from `git rev-parse HEAD` (no trailing newline required).

**When it is read:**
- By the PR agent (`pr.md`) to build the diff between the snapshot and the final HEAD.
- By the orchestrator after auto-fix to determine which phases to re-run (controlled by `on_fail_rerun`).

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

1. Read `pre-quality-snapshot.sha` from scratch dir
2. Run `git diff --name-only <sha> HEAD` to get modified files from the fix
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

**Trigger:** `git diff --name-only <sha> HEAD` returns empty after the fix agent runs.

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

**Trigger:** After the fix, `git diff --name-only` returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4.` |
| `score` | `A–F` | Quality score (see scoring table below) |
| `counts` | object | Finding counts by severity |
| `top_findings` | array | Up to 5 most severe findings; empty array if none |
| `report_path` | string | Relative path to the full markdown report |

## Scoring table

| Score | Criteria |
|-------|----------|
| A | No findings, or only `low` findings |
| B | No `critical`/`high`; at least one `medium` |
| C | No `critical`; 1–2 `high` findings |
| D | No `critical`; 3+ `high` findings |
| F | At least one `critical` finding |

## Audit-specific notes

| Audit | Gate cap | Notes |
|-------|----------|-------|
| `backend` | PASS\|WARN\|FAIL | Standard gate |
| `frontend` | PASS\|WARN\|FAIL | Standard gate |
| `database` | PASS\|WARN\|FAIL | Standard gate |
| `security` | PASS\|WARN\|FAIL | Standard gate |
| `tests` | **PASS\|WARN** | HIGH findings map to WARN, not FAIL — test gaps are a quality issue, not blocking |

## Usage in `ship:audit:run`

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step. for field definitions and scoring table.

```json
{
  "audit": "database",
  "gate": "<PASS|WARN|FAIL>",
  "score": "<A|B|C|D|F>",
  "counts": {"critical": 0, "high": 0, "medium": 0, "low": 0},
  "top_findings": [
    {"id": "<ID>", "severity": "<critical|high|medium|low>", "title": "<title>", "file": "<file:line>"}
  ],
  "report_path": "ship/audits/database-<YYYY-MM-DD>.md"
}
```

---

## Rules

- **Entire codebase scope** — not a diff. For diff-scoped analysis, use `/ship:perf`.
- **Route by config** — always read `ship/config.md` before choosing methodology.
- **Evidence required** — cite file and line; "some queries may be slow" is not a finding.
- **Exact heuristics only** — report only what matches the patterns above.
- **write-concern is the only Critical** — treat as pipeline-stopping.
- **Flag migrations explicitly** — data transformation changes: "Requires migration: Yes".
- **ALWAYS launch 3 agents in parallel** — never sequentially. Single Agent tool call.
- **Language:** See # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above..
