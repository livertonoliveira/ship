# Ship — Linear Audit Template

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
