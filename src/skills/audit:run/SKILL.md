---
name: ship:audit:run
description: "Ship Audit: meta-command that runs all applicable audits based on ship/config.md project type. Produces a consolidated report."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Audit — Run All

Determine which project-wide audits apply, launch them in parallel, consolidate into one gate report.

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Process

### 1. Applicable audits

Read `ship/config.md` (Project Type, Database, Frontend, Workspaces). `audit:security` and `audit:tests` always run.

| Project Type | DB? | Also run |
|---|---|---|
| `backend` | no | audit:backend |
| `backend` | yes | audit:backend + database |
| `frontend` | — | audit:frontend |
| `fullstack` | no | audit:backend + frontend |
| `fullstack` | yes | audit:backend + database + frontend |
| `monorepo` | varies | see below |

**Monorepo:** per `backend` workspace → audit:backend (+database if present); per `frontend` workspace → audit:frontend. One shared security + tests audit for the repo.

### 2. Launch in parallel

Announce the plan, then invoke every applicable audit skill via the **Skill tool** in one turn so they fork concurrently — never sequentially. Each declares `context: fork` + `model: sonnet` and delegates to its `ship-audit-*` agent; do NOT wrap any in an `Agent` call. Each writes its report to `ship/audits/<type>-<YYYY-MM-DD>.md`.

### 3. Consolidate

Extract the JSON summary from each tool result (see @ship/patterns/audit-summary-schema.md) — do NOT re-read the report files. Apply the gate logic inline in this context; the summaries already returned here, so a separate consolidation agent only adds a serial round-trip. Never fan out an Agent to aggregate.

**Gate:** any FAIL → **FAIL**; else any WARN → **WARN**; else **PASS**.

### 4. Write report

**Local:** `ship/audits/run-<YYYY-MM-DD>.md`. **Linear:** Document "Audit Suite — <YYYY-MM-DD>" linking each audit's document.

Include: gate result; per-audit table (severity counts + gate, TOTAL row); all critical/high findings (category, file, description, impact, suggestion) by severity then audit; unified roadmap; condensed medium/low list; links to each report.

### 5. Present

Show the gate, critical/high findings with source, and the roadmap.
- FAIL → "Pipeline is blocked. Resolve critical/high findings before proceeding."
- WARN → "Medium findings detected. Review and decide whether to proceed."
- PASS → "All audits passed. Codebase is in good shape."

---

## Rules

- Gate is pessimistic: one FAIL anywhere = overall FAIL.
- Individual reports are authoritative; the consolidated report only summarizes.
- Language: see @ship/patterns/language.md.
- Periodic, project-wide — distinct from diff-scoped `/ship:perf` and `/ship:security`. Never invoke this command from inside `/ship:run`.
