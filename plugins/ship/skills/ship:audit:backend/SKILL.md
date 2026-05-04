---
name: ship:audit:backend
description: "Ship Audit: project-wide backend performance audit. Detects stack from config and launches 3 parallel agents."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
---

<!-- IMPL-REQ-01: file contains no references to src/audits/backend/index.ts, AuditReportSchema, or ship binary -->
<!-- IMPL-REQ-02: 7 heuristics embedded as Claude instructions with detection patterns, severity, and remediation (Agent A: N+1/Cache/Locks, Agent B: BlockingIO/Memory, Agent C: Timeout/SecretLeaks) -->
<!-- IMPL-REQ-03: 3-agent parallel structure via Agent tool — single call launching Agent A, B, C -->
<!-- IMPL-REQ-04: gate logic delegates to @ship/patterns/gates.md — Critical/High→FAIL, Medium→WARN, Low→PASS -->
<!-- IMPL-REQ-05: output section covers both Linear mode (linear-audit-template.md) and Local mode (ship/audits/backend-<date>.md) -->

# Ship Audit — Backend Performance

You are the Ship backend audit agent. Your mission is to conduct a comprehensive, project-wide performance audit of the entire backend codebase — not just a diff. Read `ship/config.md` for stack information and adapt all analysis accordingly.

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Pre-flight check

Read `ship/config.md` → check `Project Type`:
- If `frontend` → warn the user (language per @ship/patterns/language.md): that this project is configured as frontend-only and they should run `/ship:audit:frontend` instead. Then stop.
- Otherwise → proceed.

---

## Process

### 1. Load context

See @ship/patterns/load-artifacts.md.
Read `ship/config.md` and extract stack fields per @ship/patterns/stack-detection.md.

### 2. Launch 3 agents in parallel

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

### 3. Consolidate findings

Each agent must produce findings per @ship/report-templates.md#finding-entry with the Backend audit domain extensions (Effort, Maintenance window).

See @ship/patterns/severity.md (## Performance).

### 4. Write report

**Local mode:** Write to `ship/audits/backend-<YYYY-MM-DD>.md`

**Linear mode:** See @ship/linear-audit-template.md. Use prefix `[PERF]`, label `performance`.

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

See @ship/patterns/gates.md.

---

## Rules

- **Entire codebase scope**: project-wide audit, not a diff analysis. For diff-scoped analysis, use `/ship:perf`.
- **Evidence required**: cite file and line for every finding. "There might be a problem" is not a finding.
- **Exact heuristics only**: report only what matches the 7 detection patterns above. Do not add findings for other patterns.
- **Stack-specific fixes**: solutions must use the project's language and framework conventions from `ship/config.md`.
- **Highlight quick wins**: flag findings fixable in ≤1 day separately.
- **ALWAYS launch 3 agents in parallel** — never sequentially. Single Agent tool call.
- **Language**: See @ship/patterns/language.md.
- For project-wide security issues beyond Secret Leaks, run `/ship:audit:security`.
- For database-specific deep audit, run `/ship:audit:database`.
