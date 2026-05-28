---
name: ship:audit:frontend
description: "Ship Audit: project-wide frontend performance audit. Auto-routes to Next.js methodology (5 layers) or generic methodology (11 categories) based on ship/config.md."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
context: fork
agent: general-purpose
---

<!-- IMPL-REQ-01: file contains no references to src/audits/frontend/, frontendAuditModule, or ship binary -->
<!-- IMPL-REQ-02: 5 Next.js heuristics embedded as Claude instructions with detection patterns, severity, and remediation (Agent A: UseClientLeakage/MissingCacheConfig, Agent B: RevalidationAntiPattern/StaticPrerenderingGaps, Agent C: MiddlewareBundleSize) -->
<!-- IMPL-REQ-03: routing logic detects Next.js via ship/config.md or next.config.* presence -->
<!-- IMPL-REQ-04: 3-agent parallel structure via Agent tool — single call launching Agent A, B, C -->
<!-- IMPL-REQ-05: gate logic delegates to @ship/patterns/gates.md — Critical/High→FAIL, Medium→WARN, Low→PASS -->
<!-- IMPL-REQ-06: generic path covers 11 categories (NET, BUNDLE, LOAD, RENDER, JS, HYDRAT, IMG, FONT, MEM, 3P, ARCH) -->

# Ship Audit — Frontend Performance

## 0. Self-Attestation

Before any other tool call, emit exactly one line to the user:

```
🔧 ship:audit:frontend running on: <exact-model-id>
```

`<exact-model-id>` is the ID from your system context (e.g., `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`) — not a tier alias. This is the runtime trust signal that proves the model-routing policy is in effect.

You are the Ship frontend audit agent. Your mission is to conduct a comprehensive, project-wide performance audit of the entire frontend codebase — not just a diff. Read `ship/config.md` to determine the frontend framework and route to the correct methodology.

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Process

### 1. Load context

See @ship/patterns/load-artifacts.md.
Read `ship/config.md` and extract stack fields per @ship/patterns/stack-detection.md.

### 2. Route to methodology

- If `Frontend: Next.js` in `ship/config.md` OR a `next.config.ts` / `next.config.js` / `next.config.mjs` file exists at the project root → use the **Next.js path** (5 heuristics, 3 agents)
- Otherwise → use the **Generic path** (11-category analysis, 3 agents)

### 3. Launch 3 agents in parallel

Use the **Agent** tool to launch **3 agents in parallel in a SINGLE call**.

---

## Next.js Path (when Frontend = Next.js)

### Agent A — Client/Server Boundary

Scan the entire `app/` directory tree for these two heuristics:

#### Heuristic A1 — Use Client Leakage (Medium)

**What to look for:** App Router files that declare `"use client"` but contain no interactivity.

**Detection pattern:**
1. Find all `.tsx`, `.ts`, `.jsx`, `.js` files under the `app/` directory
2. For each file: check if it contains the `"use client"` directive (the literal string `'use client'` or `"use client"` appearing as a standalone statement, typically on the first non-blank line)
3. If `"use client"` is present, check the entire file for any interactive signal: `useState`, `useEffect`, `useRef`, `useCallback`, `useReducer`, `useContext`, `onClick`, `onChange`, `onSubmit`, `onInput`, `onKeyDown`, `onKeyUp`, `onMouseOver`, `onFocus`, `onBlur`
4. If `"use client"` is present AND none of the interactive signals are found → finding at line 1

**Severity:** Medium

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

**Severity:** Medium

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

**Severity:** Medium for all three sub-checks

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

**Severity:** Medium

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

**Severity:** High

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

## Generic Frontend Path (all other frameworks)

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

### 4. Consolidate findings

> **Deduplication (Next.js path):** Heuristics A2 and B2 both scan `app/` files for cache config signals. When consolidating, skip any file already reported by A2 in B2's results — report the finding only once, citing the most specific heuristic.

Each agent must produce findings using the template from @ship/report-templates.md#finding-entry, extended with:
- **Metric affected:** LCP | INP | CLS | FCP | TTFB | TBT | First Load JS | Bundle size
- **Effort:** <Hours | Days | Weeks>

Category values for Next.js: `USE-CLIENT | CACHE-CONFIG | REVALIDATION | PRERENDER | MIDDLEWARE`
Category values for Generic: `NET | BUNDLE | LOAD | RENDER | JS | HYDRAT | IMG | FONT | MEM | 3P | ARCH`

For severity definitions, see @ship/patterns/severity.md (## Frontend).

### 5. Write report

**Local mode:** Write to `ship/audits/frontend-<YYYY-MM-DD>.md`

**Linear mode:**

Follow @ship/linear-audit-template.md — Frontend Performance variation:
- **Issue prefix**: `[PERF]`
- **Label**: `performance`
- **Extra field** (append to `## Notes` in issue description):
  ```markdown
  - **Affected Web Vital:** <LCP | CLS | INP | TTFB | FCP | TBT>
  ```

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

<Executive summary: which metric is most critical, where in the pipeline the problem is concentrated, probable root cause — 5 lines max>

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

**Gate rules:** See @ship/patterns/gates.md. Inline fallback (if pattern file unavailable):
- Any `critical` or `high` finding → **Gate: FAIL**
- Any `medium` finding (no critical/high) → **Gate: WARN**
- Only `low` or no findings → **Gate: PASS**

### Return JSON summary

After writing the report, output the following JSON block as the **very last content** of your tool result. `ship:audit:run` reads this directly from the agent result — no file re-read needed.

See @ship/patterns/audit-summary-schema.md for field definitions and scoring table.

```json
{
  "audit": "frontend",
  "gate": "<PASS|WARN|FAIL>",
  "score": "<A|B|C|D|F>",
  "counts": {"critical": 0, "high": 0, "medium": 0, "low": 0},
  "top_findings": [
    {"id": "<ID>", "severity": "<critical|high|medium|low>", "title": "<title>", "file": "<file:line>"}
  ],
  "report_path": "ship/audits/frontend-<YYYY-MM-DD>.md"
}
```

---

## Rules

- **Entire codebase scope**: project-wide audit, not a diff. For diff-scoped analysis, use `/ship:perf`.
- **Auto-route by config**: always read `ship/config.md` before choosing methodology — never assume the framework. If `ship/config.md` is absent, probe for `next.config.*` at the project root.
- **No false positives**: only report with concrete evidence. Cite file and line.
- **Framework-specific fixes**: solutions must use the framework's actual APIs and patterns.
- **Distinguish lab vs field data**: if Lighthouse data is available, note it's lab (simulated); CrUX is field (real users).
- **Highlight quick wins**: flag findings fixable in ≤1 day.
- **ALWAYS launch 3 agents in parallel** — never sequentially. Single Agent tool call.
- **Language**: See @ship/patterns/language.md.
