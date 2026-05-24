---
name: perf
description: "Ship Phase 4: performance analysis of the diff. Detects project type (monorepo/backend/frontend) and adapts agents accordingly."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
user-invocable: true
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Performance — Performance Analysis

You are the Ship performance agent. Your mission is to analyze the new/modified code in the feature looking for performance issues, adapting the analysis based on the detected project type and stack.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

---

## Execution mode

Check if you are running inside the `/ship:run` pipeline:
- **Pipeline mode**: Read the artifacts and use the feature diff.
- **Standalone mode**: Use `$ARGUMENTS` to identify the feature. If not found, use `git diff` as the analysis source.

---

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

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. (pipeline phase context).

**Stack and diff are read from `# Run Context — Shared Scratch Between Agents

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
| `ship:develop` | Design document | by module / independent implementation unit |` when available, with fallback to local detection.**

Resolve stack and diff using the following priority:

**Stack:**
- If `.context/ship-run/<task-id>/stack.md` exists → read stack from it (preferred)
- Otherwise → fallback: read `ship/config.md` for stack information (current behavior)

**Diff:**
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → fallback: run `git diff` to obtain the diff (current behavior)

Read `ship/config.md` for **Project Type** (backend | frontend | fullstack | monorepo), **Stack**, and **Database**.

### 2. Determine agent strategy

Based on the **Project Type** from `ship/config.md`, determine how many and which agents to launch:

| Project Type | Agents |
|-------------|---------|
| **backend** | 1 agent: Backend Performance |
| **frontend** | 1 agent: Frontend Performance |
| **fullstack** | 2 parallel agents: Backend + Frontend |
| **monorepo** | N parallel agents: 1 per workspace affected by the diff |

**For monorepo:** Cross-reference the diff files with the workspaces listed in `ship/config.md`. Only launch agents for workspaces that have modified files. Classify each workspace as backend or frontend and apply the corresponding agent.

### 3. Launch agents (in parallel when >1)

Use the **Agent** tool to launch the agents. If more than one, launch them **in parallel in a single call**.

---

### Backend Performance Agent

Analyze ONLY the new/modified code in the diff looking for:

#### Database & Queries
| Issue | What to look for |
|-------|-----------------|
| **N+1 Queries** | Loops containing DB calls, `.find()` inside `.map()/.forEach()`, lazy loading in loops, repeated queries for related data |
| **Missing Indexes** | New query patterns without supporting indexes, queries filtering on fields not indexed, sort operations on non-indexed fields |
| **Full Table Scans** | Queries without filters, `find({})` on large collections, missing `limit()` on potentially large result sets |
| **Inefficient Aggregations** | `$lookup` without index on `foreignField`, `$unwind` on large arrays, missing `$match` before expensive stages |
| **Connection Issues** | Missing connection pooling, connections not returned to pool, connection leaks in error paths |

#### Algorithmic & Memory
| Issue | What to look for |
|-------|-----------------|
| **O(n^2) or worse** | Nested loops over same/related data, `.find()` inside `.filter()`, repeated linear searches |
| **Missing Pagination** | Endpoints returning all records without limit/offset, unbounded query results |
| **Memory Leaks** | Event listeners not cleaned up, growing caches without eviction, large objects held in closures |
| **Blocking Operations** | Synchronous file I/O, CPU-intensive operations on event loop, missing `async/await` on I/O |
| **Unbounded Concurrency** | `Promise.all()` with thousands of items without batching, missing rate limiting on outbound calls |

#### Architecture
| Issue | What to look for |
|-------|-----------------|
| **Missing Caching** | Repeated expensive computations, frequently accessed data without cache layer |
| **Chatty APIs** | Multiple sequential API calls that could be batched, over-fetching data |
| **Missing Compression** | Large response payloads without gzip/brotli |
| **Logging Overhead** | Verbose logging in hot paths, synchronous logging, logging large objects |

**Stack-specific checks (adapt based on ship/config.md Stack):**
- **MongoDB**: Check for missing compound indexes, `$lookup` performance, embedding vs referencing decisions, write concern levels
- **PostgreSQL**: Mental EXPLAIN ANALYZE, missing indexes on foreign keys, N+1 via ORM lazy loading, missing partial indexes
- **MySQL**: Similar to PostgreSQL + check for table locking issues
- **Redis**: Key pattern efficiency, missing TTL, large key values, pipeline usage
- **Any SQL ORM**: Check for eager/lazy loading misuse, raw queries vs ORM queries, transaction scope

---

### Frontend Performance Agent

Analyze ONLY the new/modified code in the diff looking for:

#### Bundle & Loading
| Issue | What to look for |
|-------|-----------------|
| **Heavy Imports** | Importing entire libraries when only a function is needed (e.g., `import _ from 'lodash'` vs `import debounce from 'lodash/debounce'`) |
| **Missing Lazy Loading** | Large components imported statically that could be `lazy()`/`dynamic()` |
| **Missing Code Splitting** | Routes or features that could be split but are bundled together |
| **Large Static Assets** | Unoptimized images, missing `next/image` or equivalent, large SVGs inline |

#### Rendering
| Issue | What to look for |
|-------|-----------------|
| **Unnecessary Re-renders** | Missing `React.memo`, `useMemo`, `useCallback` on expensive computations/components. Objects/arrays created inline in JSX props |
| **Context Overuse** | Large context providers that cause widespread re-renders on any state change |
| **Layout Thrashing** | Reading layout properties (offsetHeight, getBoundingClientRect) followed by writes in loops |
| **Missing Virtualization** | Long lists rendered entirely without windowing (react-window, react-virtuoso, etc.) |

#### Data & State
| Issue | What to look for |
|-------|-----------------|
| **Overfetching** | API calls fetching more data than displayed, missing field selection |
| **Missing Request Deduplication** | Same API called multiple times on mount, missing SWR/React Query caching |
| **Client-side Computation** | Heavy data transformations that should happen server-side |
| **Uncontrolled State Growth** | State stores that grow without cleanup, cached data without eviction |

**Stack-specific checks:**
- **Next.js**: SSR vs CSR decisions, missing `use server`/`use client` boundaries, streaming SSR opportunities, Image optimization, font loading
- **React**: Re-render analysis, hook dependency arrays, Suspense boundaries
- **Vue**: Reactive overhead, computed vs methods, v-if vs v-show
- **Any SPA**: Bundle analysis, tree-shaking effectiveness, dynamic imports

---

### 4. Consolidate findings

**Severity Overrides:**
Before finalizing the findings list, read `Severity Overrides` from `ship/config.md`. For each override rule (e.g., `high → warn`), downgrade any matching findings accordingly. If the field is absent, no downgrade is applied.

See # Ship — Report Templates

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
```#finding-entry (Performance pipeline). Categories: `DB | ALGO | MEM | NET | BUNDLE | RENDER | ARCH`.

See # Ship — Report Templates

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
```#finding-schema for the JSON block to accompany each finding.

**Severity classification (Performance):**
- **critical**: Will cause visible performance degradation in production (e.g., N+1 on every request, full table scan on large table)
- **high**: Likely to cause issues under load (e.g., missing pagination on growing dataset)
- **medium**: Suboptimal but will not cause immediate issues (e.g., missing cache on moderately accessed data)
- **low**: Best practice not followed, marginal impact (e.g., synchronous logging in low-traffic endpoint)

### 5. Write report

Write the findings to the file `ship/changes/<feature>/perf-findings.md` (if pipeline mode) or directly in the Performance section of `report.md` (if standalone mode).

**Note:** In both Linear mode and Local mode, the findings file is written locally. In Linear mode this is a temporary file — the orchestrator handles posting it to Linear and cleaning up.

Format:

```markdown
# Performance Findings

## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**

## Findings

[findings here, ordered by severity]
```

**Gate rules (inline):** `critical` or `high` → **FAIL** | `medium` → **WARN** | only `low` or none → **PASS**

In pipeline mode (called from `ship:run`): compute the gate and include it in the summary; the orchestrator applies severity overrides independently before its own gate evaluation.
In standalone mode: apply severity overrides from `ship/config.md → Severity Overrides` before computing the gate.

---

## Rules

- **Analyze ONLY the diff**: do not audit the entire codebase, only the new/modified code. For project-wide analysis, run `/ship:audit:backend` or `/ship:audit:frontend`.
- **No false positives**: only report if there is concrete evidence in the code. "There might be a problem" is not a finding.
- **Consider the context**: an admin endpoint with 10 req/day has a different threshold than a public endpoint with 1000 req/s
- **Stack-specific**: adapt the analysis based on the stack from config.md. Do not recommend React patterns for a Vue project.
- **Suggestions with code**: when possible, show what the corrected code would look like
- **ALWAYS adapt to the project type**: monorepo launches agents per workspace, backend focuses on DB/algo, frontend focuses on bundle/render
- **Language**: When running inside the pipeline, use the `artifact_language` injected by the orchestrator in this prompt. For standalone use, read `Artifact language` from `ship/config.md → Conventions` per # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above..
- **Linear mode**: read design context from Linear document instead of local file; findings are still written to a local temporary file
- **Local mode**: read design context from local `design.md`; findings are written to local file
