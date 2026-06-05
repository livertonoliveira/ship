---
name: ship-audit-frontend
description: "Ship frontend audit worker — project-wide performance audit. Auto-routes to Next.js methodology (5 heuristics, 3 agents) or generic methodology (11 categories, 3 agents) based on ship/config.md."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
# Note: mcp__linear-server__* is required — audit agents write findings directly to Linear
# (Project, Document, Milestones, Issues). Pipeline agents (ship-perf, ship-review) omit it
# because they only write to scratch dir; do NOT remove it here by analogy.
model: sonnet
---

# Ship Audit — Frontend Performance Worker

You are the Ship frontend audit worker. Your mission: conduct a comprehensive, project-wide frontend performance audit — not a diff. Read `ship/config.md` to determine the framework and route to the correct methodology.

**Input received:** $ARGUMENTS (artifact language, storage mode, stack info passed by the caller)

---

## 1. Load context

**If the caller already injected `## Stack` and `## Config` sections inline in the prompt**, use ONLY that injected context — skip file reads for stack and config. Likewise, if `Artifact language` and `Storage mode` are already present in the prompt, skip reading `ship/config.md` for those fields.

**Only when invoked standalone (no inline context)**, fall back and read `ship/config.md` and extract:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language`
- `Frontend` → framework (Next.js, React, Vue, Angular, Svelte, etc.)
- `Project Type` → backend | frontend | fullstack | monorepo
- `Stack` → runtime, build tool, package manager (full stack summary)
- `Severity Overrides` → downgrade rules (if present)

If `ship/config.md` is absent or incomplete, probe the project root:
- `next.config.*` → Next.js
- `package.json` → inspect `dependencies`/`devDependencies` for framework signals

---

## 2. Route to methodology

- If `Frontend: Next.js` in `ship/config.md` **OR** a `next.config.ts` / `next.config.js` / `next.config.mjs` file exists at the project root → **Next.js path** (5 heuristics, 3 agents)
- Otherwise → **Generic path** (11-category analysis, 3 agents)

---

## 3. Launch 3 agents in parallel

Use the **Agent** tool to launch **3 agents in parallel in a SINGLE call**.

---

## Next.js Path — 3 parallel agents

### Agent A — Client/Server Boundary

Scan the entire `app/` directory tree for these two heuristics:

#### Heuristic A1 — Use Client Leakage (Medium)

**What to look for:** App Router files that declare `"use client"` but contain no interactivity.

**Detection pattern:**
1. Find all `.tsx`, `.ts`, `.jsx`, `.js` files under the `app/` directory
2. For each file: check if it contains the `"use client"` directive (the literal string `'use client'` or `"use client"` appearing as a standalone statement, typically on the first non-blank line)
3. If `"use client"` is present, check the entire file for any interactive signal: `useState`, `useEffect`, `useRef`, `useCallback`, `useReducer`, `useContext`, `onClick`, `onChange`, `onSubmit`, `onInput`, `onKeyDown`, `onKeyUp`, `onMouseOver`, `onFocus`, `onBlur`
4. If `"use client"` is present AND none of the interactive signals are found → finding at line 1

**Severity:** Medium | **Category:** `BOUNDARY`

**Remediation:** Remove `"use client"` — the component will be treated as a Server Component by default. If interactivity is needed in only part of the component tree, extract the interactive parts into a small child component with `"use client"` and keep the parent as a Server Component ("push `use client` to the leaves").

**Example fix:**
```tsx
// Before — "use client" on a display-only component
"use client"
export function ProductCard({ name, price }: Props) {
  return <div>{name} — ${price}</div>; // no state, no event handlers
}

// After — Server Component (no directive needed)
export function ProductCard({ name, price }: Props) {
  return <div>{name} — ${price}</div>;
}
```

---

#### Heuristic A2 — Missing Cache Config (Medium)

**What to look for:** Route Handler files (App Router) that export HTTP methods without an explicit cache configuration.

**Detection pattern:**
1. Find all files under `app/` that contain at least one of: `export async function GET`, `export async function POST`, `export async function PUT`, `export async function DELETE`, `export async function PATCH`, `export async function HEAD`, `export async function OPTIONS`
2. For each such file, check if ANY of these cache config signals are present anywhere in the file:
   - `export const dynamic =`
   - `export const revalidate =`
   - `cache: 'force-cache'` or `cache: 'no-store'`
   - `next: { revalidate`
   - `unstable_cache`
3. If no cache config signal is found → finding (report the line of the first matching HTTP method export)

**Severity:** Medium | **Category:** `CACHE`

**Remediation:** Add an explicit cache configuration to every Route Handler:
- `export const dynamic = 'force-dynamic'` for routes that must run on every request (auth, user-specific data)
- `export const revalidate = <seconds>` for routes that can use ISR
- `export const dynamic = 'force-static'` for routes with no dynamic data

**Example fix:**
```ts
// Explicit: cache product categories for 1 hour
export const revalidate = 3600;

export async function GET() {
  const categories = await getCategories();
  return Response.json(categories);
}
```

---

### Agent B — Cache & Revalidation

Scan the entire `app/` directory tree for these two heuristics:

#### Heuristic B1 — Revalidation Anti-Pattern (Medium)

**What to look for:** Three specific anti-patterns that defeat ISR caching.

**Detection pattern (3 independent sub-checks per file):**

1. **`revalidate = 0`**: Search for `export const revalidate = 0`. If found → finding: "`revalidate = 0` disables ISR (effectively force-dynamic)"
2. **Low revalidate interval**: Search for `export const revalidate =` followed by a value of 1 through 10 (single digit, or exactly `10`). Regex equivalent: `export const revalidate = (10|[1-9])\b`. If found → finding: "ISR revalidate interval too low (≤ 10 seconds)"
3. **Root path invalidation**: Search for `revalidatePath('/')` or `revalidatePath("/")`. If found → finding: "`revalidatePath('/')` busts all cached routes on every mutation"

Note: sub-checks 1 and 2 are mutually exclusive per file. Sub-check 3 is independent and may co-occur with either.

**Severity:** Medium for all three sub-checks | **Category:** `REVALIDATION`

**Remediation:**
- Replace `revalidate = 0` with `export const dynamic = 'force-dynamic'` to signal explicit SSR intent; or set a positive value if the data tolerates brief caching
- For low revalidate intervals: raise the value to match actual data change frequency (e.g., `3600` for product listings, `86400` for static content)
- Replace `revalidatePath('/')` with scoped invalidation:
  ```ts
  revalidatePath('/products')       // scope to one route
  revalidateTag('products-list')    // or tag-based invalidation
  ```

---

#### Heuristic B2 — Static Prerendering Gaps (Medium)

**What to look for:** App Router files that perform data fetching without explicit cache configuration, risking accidental SSR.

**Detection pattern:**
1. Find all files in the `app/` directory tree
2. For each file, check if it contains any data fetch call:
   - `await fetch(`
   - `await prisma.`, `await db.`, `await orm.`, `await supabase.`, `await drizzle.`, `await repository.`, `await dataSource.`
   - (do NOT flag generic `await client.` — too broad; only flag the specific ORM/client names above)
3. If a data fetch is found, check the entire file for ANY explicit cache config signal:
   - `export const revalidate =`
   - `export const dynamic =`
   - `cache: 'force-cache'` or `cache: 'no-store'`
   - `next: { revalidate`
   - `unstable_cache`
   - `generateStaticParams`
4. If data fetch is present AND no cache config signal → finding (report the line of the first data fetch call)

**Severity:** Medium | **Category:** `PRERENDER`

**Deduplication:** Heuristics A2 and B2 both scan `app/` files for cache config signals. When consolidating, skip any file already reported by A2 in B2's results — report the finding only once, citing the most specific heuristic.

**Remediation:**
- Add a file-level `export const revalidate` or `export const dynamic` directive
- For `fetch()` calls, add inline cache options: `fetch(url, { next: { revalidate: 3600 } })`
- For direct DB queries in Server Components, wrap with `unstable_cache`:
  ```ts
  import { unstable_cache } from 'next/cache'

  const getProducts = unstable_cache(
    async () => db.select().from(products),
    ['products'],
    { revalidate: 3600, tags: ['products'] }
  )
  ```

---

### Agent C — Edge Runtime / Middleware

Scan the project root and `src/` directory for this heuristic:

#### Heuristic C1 — Middleware Bundle Size (High)

**What to look for:** Heavy library imports in Next.js middleware files.

**Detection pattern:**
1. Locate middleware files: check for `middleware.ts`, `middleware.js`, `src/middleware.ts`, `src/middleware.js` (use the first found)
2. If no middleware file is found → no findings (skip heuristic)
3. For each found middleware file, scan all `import` statements — lines matching `import ... from '<package>'`
4. Flag any import whose package name equals or starts with any of these heavy libraries:
   - **Date/utility**: `lodash`, `moment`, `moment-timezone`, `date-fns`
   - **HTTP client**: `axios`
   - **UI frameworks/styling**: `@mui/`, `@chakra-ui/`, `@emotion/`, `styled-components`
   - **Node-heavy utilities**: `react-dom`, `sharp`, `fs-extra`, `rimraf`, `glob`
   - **Database drivers / ORMs**: `pg`, `mysql`, `mysql2`, `mongodb`, `@prisma/client`, `prisma`, `typeorm`, `sequelize`, `mongoose`, `drizzle-orm`
   - **Validation**: `yup`, `joi`, `class-validator`
5. Each unique heavy package found in middleware → one finding

**Severity:** High | **Category:** `MIDDLEWARE`

**Why this matters:** Next.js middleware runs on every request in the Edge Runtime, which has a 1 MB bundle size limit. Heavy imports inflate cold-start latency, may exceed the limit (causing deployment failures), and degrade performance for all users on every page load.

**Remediation:**
- **Date formatting**: Use `Intl.DateTimeFormat` (native Edge API) instead of `moment`/`date-fns`
- **HTTP**: Use native `fetch` (available in Edge Runtime) instead of `axios`
- **Database access**: Move DB logic to a Route Handler (`export const runtime = 'nodejs'`) and call it from middleware via `fetch` if needed — never query the DB directly from middleware
- **Validation**: Replace `yup`/`joi`/`class-validator` with `zod` (Edge-compatible)
- If the logic genuinely requires a heavy library, move it out of middleware to a Route Handler with Node.js runtime

**Example fix:**
```ts
// Before — imports DB driver (Edge Runtime incompatible)
import { PrismaClient } from '@prisma/client'; // ❌

export async function middleware(request: NextRequest) {
  const db = new PrismaClient();
  const user = await db.user.findUnique({ where: { id: request.headers.get('x-user-id') } });
  // ...
}

// After — delegate to Route Handler
export async function middleware(request: NextRequest) {
  const res = await fetch(`${request.nextUrl.origin}/api/internal/auth`, {
    headers: { 'x-user-id': request.headers.get('x-user-id') ?? '' },
  });
  // ...
}
```

> **Next.js path → proceed to steps 4 and 5 below** (Consolidate findings + Write report).

---

## Generic Frontend Path — 3 parallel agents

> **Static analysis only**: all findings must be based on source code, config files, or build artifacts — not runtime metrics. If a problem can only be confirmed at runtime (e.g., actual TTFB values), report it as a hypothesis in the Blind Spots section, not as a finding.

### Agent A — NET + BUNDLE + LOAD

#### Network / Assets
| Issue | Static indicator to look for |
|---|---|
| **No CDN** | No CDN config in deployment files (`vercel.json`, `netlify.toml`, `cloudfront.json`, `nginx.conf`); custom server with `express.static()` serving files directly |
| **Assets without cache headers** | `express.static()` without `maxAge` option; no `Cache-Control` header in server middleware or config |
| **No compression** | Express app without `compression()` middleware; NestJS without `CompressionModule`; Fastify without `@fastify/compress` |
| **Missing streaming (potential TTFB)** | SSR entry point (`getServerSideProps`, route `loader`) with sequential `await` DB/API calls that could use `Promise.all` or `Suspense` |

#### Bundle
| Issue | Static indicator to look for |
|---|---|
| **Heavy imports** | `import _ from 'lodash'` or `import * as R from 'ramda'` — full library imported when only one function is used |
| **No code splitting** | Single large bundle entry; no `dynamic(() => import(...))`, no `React.lazy()`, no route-level splitting |
| **Tree shaking failures** | Barrel files (`index.ts`) that re-export all named exports; check `src/index.ts`, `components/index.ts` |
| **Duplicate dependencies** | Two `package.json` files declaring different versions of the same library (monorepo); check `node_modules/.pnpm` or `yarn.lock` for duplicate entries |
| **Dev-only code in production** | `process.env.NODE_ENV` guard missing around devtools imports; `devtools`, `redux-devtools-extension` imported unconditionally |

#### Loading Strategy
| Issue | Static indicator to look for |
|---|---|
| **Render-blocking CSS/JS** | `<link rel="stylesheet">` or `<script src=...>` in `<head>` without `async` or `defer` attributes in HTML template / `_document.tsx` |
| **Missing lazy loading** | Large page sections or routes imported with static `import` instead of `dynamic()`/`React.lazy()` |
| **Preload misuse** | More than 5 `<link rel="preload">` in `<head>` — over-preloading competes for bandwidth |
| **Missing resource hints** | External domains used in `fetch()` or `<img src=...>` without a matching `<link rel="preconnect">` |

---

### Agent B — RENDER + JS + HYDRAT + ARCH

#### Rendering / Paint
| Issue | Static indicator to look for |
|---|---|
| **Layout thrashing** | Reading `offsetHeight`, `offsetWidth`, `getBoundingClientRect`, `scrollTop` inside a loop that also writes to the DOM |
| **Missing GPU compositing** | CSS `transition` or `animation` on `top`, `left`, `width`, `height`, `margin`, `padding`, or `box-shadow` instead of `transform`/`opacity` |
| **Missing virtualization** | `.map(` rendering a list in JSX without `react-window`, `react-virtual`, `@tanstack/virtual`, or `react-virtuoso` |

#### JavaScript Execution
| Issue | Static indicator to look for |
|---|---|
| **Synchronous heavy work** | `JSON.parse` / `JSON.stringify` on large payloads, `sort()` or `filter()` over arrays >1000 items, or complex regex (`/[...]{5,}/`) inside a render path (component body or event handler) |
| **Missing `useMemo` / `useCallback`** | Expensive inline computations or object/array literals directly in JSX props without memoization |
| **Unnecessary re-renders** | Expensive components (marked with `// expensive`, wrapping large trees) without `React.memo`; inline `{}` or `[]` in JSX props |
| **Context overuse** | Context value updated on every state change where value is an object created inline (`value={{ ... }}`), causing all consumers to re-render |
| **Event listeners not cleaned up** | `addEventListener` inside `useEffect` without a `return () => removeEventListener(...)` cleanup |

#### Hydration
| Issue | Static indicator to look for |
|---|---|
| **Hydration mismatches** | `Date.now()`, `Math.random()`, `window.*`, or `document.*` used directly in component render (not inside `useEffect`) |
| **Over-hydration** | Pure display components (no state, no handlers) with SSR that could use `{ ssr: false }` or server-only rendering |
| **Hydration waterfall** | Nested components each with their own `useEffect` data fetch — should be lifted or parallelized |

#### Architecture
| Issue | Static indicator to look for |
|---|---|
| **Request waterfalls** | Component B's data fetch depends on data from Component A's fetch — look for prop-drilling of IDs followed by a new fetch |
| **Over-fetching** | API call response used with only 2–3 fields but response type/schema has 10+ fields; no GraphQL field selection or query parameter filtering |
| **Missing SWR / React Query** | `useEffect` + `useState` for remote data fetching without `swr`, `@tanstack/react-query`, or equivalent |
| **Client-side computation** | Heavy array transformations (`sort`, `reduce`, `groupBy`) on data from an API call — should be server-side or memoized |

---

### Agent C — IMG + FONT + MEM + 3P

#### Images / Media
| Issue | Static indicator to look for |
|---|---|
| **Unoptimized images** | `<img src=...>` without `width`/`height` attributes (causes CLS); image files in `public/` without WebP/AVIF alternatives |
| **Missing lazy loading** | `<img>` tags for below-the-fold images (not in hero section) without `loading="lazy"` |
| **Missing srcset** | `<img>` without `srcset` or `sizes` attributes; full-resolution images used for thumbnails |
| **Large SVGs inlined** | SVG files >10KB inlined directly in JSX/HTML instead of referenced as external files |
| **Autoplay video** | `<video autoplay>` without `muted` and `preload="none"` — causes layout shift and bandwidth waste on load |

#### Fonts
| Issue | Static indicator to look for |
|---|---|
| **FOUT / FOIT** | `@font-face` declarations in CSS without `font-display: swap` or `font-display: optional` |
| **Fonts not preloaded** | Custom fonts used in above-the-fold content (e.g., `h1`, hero text) without `<link rel="preload" as="font">` in the document head |
| **Too many font variants** | More than 4 different `font-weight`/`font-style` combinations loaded for a single font family |

#### Memory
| Issue | Static indicator to look for |
|---|---|
| **Memory leaks in SPA** | `addEventListener`, `setInterval`, or `subscribe(` inside `useEffect` without a cleanup `return` function |
| **Unbounded state growth** | Array or object state that only ever appends (`[...prev, newItem]`) with no upper bound or eviction |
| **Closures accumulating** | Large objects referenced inside `useCallback` without exhaustive deps — stale closure retaining previous render's data |

#### Third-party Scripts
| Issue | Static indicator to look for |
|---|---|
| **Render-blocking third parties** | Analytics (`gtag`, `fbq`, `_hsq`), chat widgets, or ad scripts loaded via `<script src=...>` in `<head>` without `async`/`defer` or `<Script strategy="lazyOnload">` |
| **Undeferred scripts** | `<script src=...>` without `async` or `defer` in HTML template |
| **Missing facades** | `<iframe src="https://www.youtube.com/...">` or Intercom/Zendesk scripts loaded eagerly on page load instead of on user interaction |

---

## 4. Consolidate findings

Read `Severity Overrides` from injected context (or `ship/config.md`) and apply downgrade rules before finalizing.

Each agent must produce findings using the template from # Ship — Report Templates

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
- **Sugestão:** Crie um teste para o critério AC-03.
```

#### FAIL (critical findings)
```
### [CRITICAL] Requisito não implementado: REQ-05
- **Categoria:** IMPL
- **Descrição:** O requisito "REQ-05: Cache invalidation" não possui implementação identificada.
- **Sugestão:** Implemente o requisito REQ-05 no arquivo.
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

+ 3 low-severity findings — [see full report](https://linear.app/<workspace>/issue/<TEAM>-NNN)

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
- **Metric affected:** LCP | INP | CLS | FCP | TTFB | TBT | First Load JS | Bundle size
- **Effort:** <Hours | Days | Weeks>

Category values for Next.js: `STRATEGY | BOUNDARY | CACHE | REVALIDATION | PRERENDER | MIDDLEWARE | ARCH`
Category values for Generic: `NET | BUNDLE | LOAD | RENDER | JS | HYDRAT | IMG | FONT | MEM | 3P | ARCH`

For severity definitions, see # Severity Definitions

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

Effect: `high` perf findings → WARN gate; `medium` security findings → treated as `low` (PASS if no other critical/high). Each phase applies only its own override. (## Frontend).

**Gate rules:** See # Gate Rules

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
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4..

---

## 5. Write report

**Report format:**
```markdown
# Frontend Performance Audit — <YYYY-MM-DD>
Framework: <Next.js | React | Vue | ...>
Methodology: <Next.js 5-heuristic | Generic 11-category>

## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**

## General Diagnosis
<Executive summary: most critical metric, where in the pipeline the problem is concentrated, probable root cause — 5 lines max>

## Core Web Vitals Status
| Metric | Status | Note |
|--------|--------|------|
| LCP | Good / Needs Improvement / Poor | |
| INP | Good / Needs Improvement / Poor | |
| CLS | Good / Needs Improvement / Poor | |

## Findings
[findings ordered by severity — high first]

## Prioritized Roadmap
| Priority | Finding | Category | Metric | Est. Impact | Effort | Quick win? |
|----------|---------|----------|--------|-------------|--------|------------|

## Validation Metrics
| Finding | Metric | Current | Target | How to measure |
|---------|--------|---------|--------|----------------|

## Blind Spots
| Hypothesis | Why unconfirmed | What to collect |
|------------|----------------|-----------------|
```

**Local mode:** Write to `ship/audits/frontend-<YYYY-MM-DD>.md`

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
  ``` — Frontend Performance variation:
- **Issue prefix**: `[PERF]`
- **Label**: `performance`
- **Extra field** (append to `## Notes` in issue description): `- **Affected Web Vital:** <LCP | CLS | INP | TTFB | FCP | TBT>`

---

## 6. Emit machine-readable summary

After writing the report, emit the JSON block per # Audit Summary Schema

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

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step. with `audit=frontend` and `report_path=ship/audits/frontend-<YYYY-MM-DD>.md`. `ship:audit:run` reads this directly from the agent result — no file re-read needed.

---

## Rules

- **Entire codebase scope**: project-wide audit, not a diff. For diff-scoped analysis, use `/ship:perf`.
- **Auto-route by config**: always read `ship/config.md` before choosing methodology. If absent, probe for `next.config.*`.
- **No false positives**: only report with concrete evidence. Cite file and line.
- **Framework-specific fixes**: solutions must use the framework's actual APIs and patterns.
- **Distinguish lab vs field data**: if Lighthouse data is available, note it's lab (simulated); CrUX is field (real users).
- **ALWAYS launch 3 agents in parallel** — never sequentially. Single Agent tool call.
- **Highlight quick wins**: flag findings fixable in ≤1 day.
- **Language**: use the `Artifact language` passed by the caller for all user-facing output. Code, variable names: always English.
- **Read efficiency**: do NOT re-read files after Edit/Write. Re-read only if explicitly requested or compaction is suspected.
