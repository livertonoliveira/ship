---
name: ship-audit-backend
description: "Ship audit worker — project-wide backend performance audit. Launches 3 parallel agents (DB+Cache+Locks, I/O+Memory, Network+Security-Adjacent) and produces a structured findings report."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Backend Performance Worker

You are the Ship backend audit worker. Your mission: conduct a comprehensive, project-wide performance audit of the entire backend codebase — not just a diff.

**Input received:** $ARGUMENTS (artifact language, storage mode, stack info, and team ID passed by the caller)

---

## 1. Load context

**If the caller already injected `## Config` or `## Stack`** sections inline in the prompt, use ONLY that injected context — skip file reads for those fields.

**Only when invoked standalone (no inline context)**, fall back:
- Read `ship/config.md` for `Linear Integration`, `Artifact language`, stack, and `Team ID`

---

## 2. Pre-flight check

Read `ship/config.md` → check `Project Type`:
- If `frontend` → warn the user that this project is configured as frontend-only and they should run `/ship:audit:frontend` instead. Then stop.
- Otherwise → proceed.

---

## 3. Launch 3 agents in parallel

Use the **Agent** tool to launch **3 agents in parallel in a SINGLE call**. Each agent scans the entire backend source tree looking for the specific heuristics assigned to it.

---

### Agent A — DB + Cache + Locks

Scan the entire codebase for these three heuristics:

#### Heuristic A1 — N+1 Queries (Medium)

**What to look for:** An `async` callback inside `.forEach(async` or `.map(async` that contains a database query within the next 30 lines of the loop declaration.

**Detection pattern:**
1. Find any line matching `.forEach(async` or `.map(async`
2. Look at the next 30 lines for any `await` call to DB methods: `find`, `findOne`, `findMany`, `findAndCount`, `query`, `execute`, `select`, `insert`, `update`, `delete`, `count`, `save`, `remove`, `getMany`, `getOne`
3. Report the line of the loop declaration as the finding location

**Severity:** Medium

**Remediation:** Replace the sequential async loop with a batched approach:
- Pre-fetch all required IDs in a single query before the loop
- Use `Promise.all` over the pre-fetched list if parallelism is needed
- Use JOIN / `include` / eager loading (e.g., Prisma `include`, TypeORM `relations`, Drizzle `with`) to fetch related data in one round trip

**Example fix:**
```typescript
// Before (N+1)
const users = await userRepo.findMany();
const results = await Promise.all(
  users.map(async (user) => {
    const orders = await orderRepo.findMany({ where: { userId: user.id } }); // 1 query per user
    return { ...user, orders };
  })
);

// After (1 query)
const users = await userRepo.findMany({ include: { orders: true } });
```

---

#### Heuristic A2 — Missing Cache (Low)

**What to look for:** GET endpoints without a cache directive. Apply judgment: skip endpoints that are clearly user-specific (route contains `:id`, `me`, `profile`, `dashboard`) or that are obviously dynamic (route contains `search`, `filter`, `stream`). Report only endpoints that appear to serve shared, relatively static data.

**Detection pattern:**
- **NestJS**: Find lines with `@Get(`. Look at the 5 lines **before** that decorator for `@CacheKey(`. If absent, and the route path does not match the skip patterns above → finding.
- **Express / Fastify**: Find lines with `router.get(`, `app.get(`, or `fastify.get(`. Look at the next 30 lines for `Cache-Control`. If absent, and the route path does not match the skip patterns above → finding.

**Severity:** Low

**False-positive guidance:** Do NOT flag `@Get(':id')`, `@Get('me')`, `@Get(':userId/orders')`, or any route with a dynamic segment that implies user-specific data. Only flag clearly shared, read-heavy routes (e.g., `@Get('categories')`, `@Get('config')`, `@Get('products')`).

**Remediation:** Add cache directives for read-heavy, shared-data endpoints:
- **NestJS**: Add `@CacheKey('key')` and `@CacheTTL(60)` decorators; enable `CacheModule` in the module
- **Express**: Add `res.setHeader('Cache-Control', 'public, max-age=60')` or a caching middleware

---

#### Heuristic A3 — Pessimistic Locks (Medium)

**What to look for:** `FOR UPDATE` SQL clauses used without proper timeout guards or outside an explicit transaction.

**Detection pattern (two sub-checks for each `FOR UPDATE` occurrence):**
1. **Missing timeout guard**: Look at 3 lines before and 3 lines after the `FOR UPDATE` line. If none of them contain `NOWAIT`, `SKIP LOCKED`, or `lock_timeout` → finding (Medium): "FOR UPDATE without timeout or SKIP LOCKED"
2. **Missing transaction**: Look at 20 lines before and 20 lines after the `FOR UPDATE` line. If none contain `BEGIN`, `START TRANSACTION`, `.transaction(`, `withTransaction(`, or `transactional` → finding (Medium): "FOR UPDATE used outside explicit transaction"

Note: Both findings may fire for the same `FOR UPDATE` occurrence.

**Severity:** Medium

**Remediation:**
- Add `NOWAIT` or `SKIP LOCKED` to avoid indefinite blocking under contention:
  ```sql
  SELECT * FROM orders WHERE id = $1 FOR UPDATE SKIP LOCKED
  ```
- Always wrap pessimistic locks in an explicit transaction:
  ```typescript
  await db.transaction(async (trx) => {
    const row = await trx.raw('SELECT * FROM orders WHERE id = ? FOR UPDATE NOWAIT', [id]);
    // ... update logic
  });
  ```
- Alternatively, set `lock_timeout` before the query: `SET LOCAL lock_timeout = '5s'`

---

### Agent B — I/O + Memory

Scan the entire codebase for these two heuristics:

#### Heuristic B1 — Blocking I/O (Medium)

**What to look for:** Synchronous I/O calls inside async handlers.

**Detection pattern:**
1. Find any line containing one of these synchronous calls: `readFileSync(`, `writeFileSync(`, `appendFileSync(`, `existsSync(`, `mkdirSync(`, `readdirSync(`, `statSync(`, `lstatSync(`, `unlinkSync(`, `copyFileSync(`, `renameSync(`, `execSync(`, `spawnSync(`, `chmodSync(`
2. Look at the 30 lines **before** that call for an async context: `async function`, `async (`, or `async <identifier>` (arrow function)
3. If an async context is found → finding

**Severity:** Medium

**Remediation:** Replace with the async equivalent to avoid blocking the event loop:

| Sync (avoid) | Async (use instead) |
|---|---|
| `fs.readFileSync` | `fs.promises.readFile` |
| `fs.writeFileSync` | `fs.promises.writeFile` |
| `fs.existsSync` | `fs.promises.access` |
| `fs.mkdirSync` | `fs.promises.mkdir` |
| `execSync` | `exec` from `node:child_process` (promisified) |

```typescript
// Before
async function handler(req, res) {
  const data = fs.readFileSync('./config.json', 'utf8'); // blocks event loop
}

// After
async function handler(req, res) {
  const data = await fs.promises.readFile('./config.json', 'utf8');
}
```

---

#### Heuristic B2 — Memory Growth (Medium)

**What to look for:** `Map` or `Set` instances created at module scope with no eviction strategy.

**Detection pattern:**
1. Find lines matching: `const <name> = new Map(` or `const <name> = new Set(` (including generic type parameters like `new Map<string, T>()`) at module level (top-level `const`/`let`/`var`)
2. Search the **entire file** for any eviction pattern: `.delete(`, `.clear(`, `LRU`, `lru-cache`, `maxSize`, `MAX_SIZE`
3. If no eviction pattern is found anywhere in the file → finding

**Severity:** Medium

**Remediation:** Add a bounded eviction strategy:
```typescript
// Before — unbounded growth
const sessionCache = new Map<string, Session>();

// After — LRU with size limit
import { LRUCache } from 'lru-cache';
const sessionCache = new LRUCache<string, Session>({ max: 1000, ttl: 1000 * 60 * 15 });
```

Alternatives:
- Add periodic `.clear()` calls with `setInterval` if full invalidation is acceptable
- Use `.delete(key)` on explicit expiry events
- Switch to Redis or another external cache for production workloads

---

### Agent C — Network + Security-Adjacent

Scan the entire codebase for these two heuristics:

#### Heuristic C1 — Request Timeout (Medium)

**What to look for:** HTTP requests via `axios` or `fetch` with no timeout configured.

**Detection pattern:**
1. Find lines matching:
   - **axios**: `axios.get(`, `axios.post(`, `axios.put(`, `axios.patch(`, `axios.delete(`, `axios.request(`, `axios.head(`, or `axios({`
   - **fetch**: `fetch(`
2. Look at the **next 10 lines** for a timeout configuration: the word `timeout`, `AbortController`, or `AbortSignal.timeout`
3. If no timeout is found → finding

**Severity:** Medium

**Remediation:**

```typescript
// axios — add timeout option
const response = await axios.get(url, { timeout: 5000 }); // 5 seconds

// fetch — use AbortSignal.timeout (Node 18+)
const response = await fetch(url, { signal: AbortSignal.timeout(5000) });

// fetch — fallback for older runtimes
const controller = new AbortController();
const timeoutId = setTimeout(() => controller.abort(), 5000);
try {
  const response = await fetch(url, { signal: controller.signal });
} finally {
  clearTimeout(timeoutId);
}
```

Without a timeout, a slow or unresponsive upstream will hold a connection indefinitely, exhausting connection pools and causing cascading failures under load.

---

#### Heuristic C2 — Secret Leaks (High)

**What to look for:** Log statements that appear to log variables with secret-indicating names.

**Detection pattern:**
1. Find lines matching a log call: `console.error(`, `console.warn(`, `console.info(`, `console.debug(`, `logger.error(`, `logger.warn(`, `logger.info(`, `logger.debug(`, `log.error(`, `log.warn(`, `log.info(`, `log.debug(` (case-insensitive, allowing spaces around the `.`)
2. Look at a window of 2 lines **before** through 3 lines **after** the log statement
3. If that window contains any of these secret-indicating names (case-insensitive): `password`, `passwd`, `secret`, `token`, `apiKey`, `api_key`, `credential`, `auth_token`, `authToken`, `private_key`, `privateKey`, `bearer` → finding

**Severity:** High

**Remediation:** Never log variables whose names suggest they contain secrets:
```typescript
// Before — leaks token value to logs
logger.error('Auth failed', { userId, token, password });

// After — log only safe context
logger.error('Auth failed', { userId, reason: 'invalid_credentials' });
```

If you need to log request context for debugging, use a structured logger that redacts sensitive fields:
```typescript
// Using pino redact
const logger = pino({ redact: ['password', 'token', 'apiKey', '*.secret'] });
```

Logging sensitive values can expose them to log aggregation systems (Datadog, CloudWatch, ELK), violate compliance requirements (PCI-DSS, GDPR/LGPD), and be exfiltrated by anyone with log-read access.

---

## 4. Consolidate findings

Each agent produces findings per ## Finding Entry {#finding-entry}

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

**Tests audit** (`audit/tests.md`) — category: `TEST`
```markdown
- **Layer:** <unit | integration | e2e>                                # adds
- **Current confidence:** <0.0–1.0>                                    # adds
- **Closest test match:** <path or none>                               # adds
- **Effort:** <Hours | Days>                                           # adds
- **Suggestion:** <Fix snippet — example test that would cover the AC/SC>  # specializes Suggestion
```

--- with the Backend audit domain extensions (Effort, Maintenance window).

Severity definitions: see # Severity Definitions

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

> **No override markers.** Correlation is keyword-based only. Ship never emits spec-ID comments (`IMPL-REQ-XX`, `IMPL-SC-XX`, `TEST-REQ-XX`, `TEST-AC-XX`, `TEST-SC-XX`) into source or test files, so the drift/coverage analyzers never scan for them. When requirement names don't match code naming (e.g., spec says "cache invalidation" but code uses "eviction"), the item surfaces as **uncertain** — the fix is to rename the code/test to match the spec vocabulary, never to annotate it with a marker comment.

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

Effect: `high` perf findings → WARN gate; `medium` security findings → treated as `low` (PASS if no other critical/high). Each phase applies only its own override. (## Performance).

Apply severity overrides from `ship/config.md → Severity Overrides` (phase: `backend`) before gate decision.

Gate rules: see # Gate Rules

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

`analyze` dispatches in the same Phase 4 parallel turn as `perf`/`security`/`review` and its findings feed the same single aggregated gate in Phase 5 (see `run/SKILL.md` → Phase 4/5) — it does not run a second gate cycle of its own. Its row in `phase-status.md` follows the identical run/timestamp/gate schema as the other three:

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
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4..

---

## 5. Write report

**Report format:**

```markdown
# Backend Performance Audit — <YYYY-MM-DD>

## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**

## General Diagnosis

<Executive summary: main bottlenecks found, root causes, heuristics with most findings — 5 lines max>

## Findings

[findings ordered by severity — high first]

## Prioritized Roadmap

| Priority | Finding | Heuristic | Est. Impact | Effort | Quick win? |
|----------|---------|-----------|-------------|--------|------------|
| 1 | ... | N+1 Queries | -70% p99 | Hours | yes |

## Validation Metrics

| Finding | Metric | Current | Target |
|---------|--------|---------|--------|
| ... | p95 latency | 800ms | <200ms |

## Blind Spots

| Hypothesis | Why unconfirmed | What to collect |
|------------|----------------|-----------------|
| ... | ... | ... |
```

### Local mode

Write to `ship/audits/backend-<YYYY-MM-DD>.md`.

### Linear mode

Apply the Linear audit template: see # Ship — Linear Audit Template

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
  ``` (Backend Performance variation). Use issue prefix `[PERF]`, label `performance`.

---

## 6. Return JSON summary

After writing the report, output the audit summary JSON block as the **very last content** of your response. `ship:audit:run` reads this directly from the agent result — no file re-read needed.

Emit the JSON per # Audit Summary Schema

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
| `gate` | `PASS\|WARN\|FAIL` | Gate result per `the gates.md pattern (included above)` |
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

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step. with `audit=backend` and `report_path=ship/audits/backend-<YYYY-MM-DD>.md`.
