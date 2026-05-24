---
name: audit:run
description: "Ship Audit: meta-command that runs all applicable audits based on ship/config.md project type. Produces a consolidated report."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
---

# Ship Audit — Run All

You are the Ship audit orchestrator. Your mission is to determine which audits apply to this project, launch them as parallel agents, and consolidate the results into a unified audit report with a single gate decision.

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Process

### 1. Load context

Read `ship/config.md` and extract:
- **Project Type** (backend | frontend | fullstack | monorepo)
- **Database** (MongoDB | PostgreSQL | MySQL | none)
- **Frontend** (Next.js | React | Vue | none | etc.)
- **Workspaces** (if monorepo)

### 2. Determine applicable audits

> **`audit:tests` is always included regardless of project type.**

Use this routing table:

| Project Type | Database configured? | Audits to run |
|---|---|---|
| `backend` | yes | audit:backend + audit:database + audit:security + audit:tests |
| `backend` | no | audit:backend + audit:security + audit:tests |
| `frontend` | — | audit:frontend + audit:security + audit:tests |
| `fullstack` | yes | audit:backend + audit:database + audit:frontend + audit:security + audit:tests |
| `fullstack` | no | audit:backend + audit:frontend + audit:security + audit:tests |
| `monorepo` | varies | See monorepo logic below + audit:tests |

**Monorepo logic:**
- Read the `Workspaces` section of `ship/config.md`
- For each workspace classified as `backend`: run `audit:backend` + `audit:security` for that workspace
- For each workspace classified as `frontend`: run `audit:frontend` for that workspace
- If any workspace has a database configured: run `audit:database`
- Always include one `audit:security` covering the full monorepo
- Always include one `audit:tests` covering the full monorepo

### 3. Announce the plan

Before launching agents, output:

```
Running Ship audit suite for <Project Type> project:
- audit:backend    [yes | no]
- audit:frontend   [yes | no]
- audit:database   [yes | no — <DB type>]
- audit:security   [yes]
- audit:tests      [yes]

Launching <N> audits in parallel...
```

### 4. Launch all applicable audits in parallel

Use the **Agent** tool to launch all applicable audit agents **in a SINGLE parallel call**. Each agent should be instructed to run its respective audit command logic:

- **audit:backend agent**: run the full `/ship:audit:backend` analysis (read that command's instructions) and return the findings report
- **audit:database agent**: run the full `/ship:audit:database` analysis and return the findings report
- **audit:frontend agent**: run the full `/ship:audit:frontend` analysis and return the findings report
- **audit:security agent**: run the full `/ship:audit:security` analysis and return the findings report
- **audit:tests agent**: run the full `/ship:audit:tests` analysis and return the findings report

Each agent writes its own report file:
- `ship/audits/backend-<YYYY-MM-DD>.md`
- `ship/audits/database-<YYYY-MM-DD>.md`
- `ship/audits/frontend-<YYYY-MM-DD>.md`
- `ship/audits/security-<YYYY-MM-DD>.md`
- `ship/audits/tests-<YYYY-MM-DD>.md`

### 5. Consolidate results

After all agents complete, each agent's tool result contains a JSON summary block (see @ship/patterns/audit-summary-schema.md). Extract those summaries directly from the tool results — **do NOT re-read the markdown report files**.

Use the **Agent** tool to consolidate results. Pass `model: "haiku"` to this consolidation agent — it performs template/report aggregation, not reasoning.

Pass the extracted JSON summaries **inline** in the consolidation agent's prompt. Instruct the agent to:
1. Use the provided JSON summaries (already included in the prompt — no file reads needed)
2. Evaluate the consolidated gate logic (see below)
3. Return the full consolidated summary report as its output

The orchestrator (Step 6) is responsible for writing the output to the correct path.

**Consolidated gate logic:**
- If ANY individual audit gate = **FAIL** → consolidated gate = **FAIL**
- If ANY individual audit gate = **WARN** (and none FAIL) → consolidated gate = **WARN**
- All **PASS** → consolidated gate = **PASS**

### 6. Write consolidated report

**Local mode:** Write to `ship/audits/run-<YYYY-MM-DD>.md`

**Linear mode:**
1. Create a Linear Document titled "Audit Suite — <YYYY-MM-DD>" with the consolidated report
2. Individual audit documents (backend, database, frontend, security, tests) were already created by each agent
3. Link all documents together in the consolidated report

**Consolidated report format:**

```markdown
# Ship Audit Suite — <YYYY-MM-DD>

## Gate Result

**PASS | WARN | FAIL**

## Summary by Audit

| Audit | Critical | High | Medium | Low | Gate |
|-------|----------|------|--------|-----|------|
| Backend Performance | X | X | X | X | PASS/WARN/FAIL |
| Database | X | X | X | X | PASS/WARN/FAIL |
| Frontend Performance | X | X | X | X | PASS/WARN/FAIL |
| Security | X | X | X | X | PASS/WARN/FAIL |
| Test Coverage | X | X | X | X | PASS/WARN/FAIL |
| **TOTAL** | **X** | **X** | **X** | **X** | **PASS/WARN/FAIL** |

## Critical and High Findings (All Audits)

[All critical and high findings from all audits, ordered by severity then audit type]

### [SEVERITY] <Finding Title> — <Audit Type>
- **Category:** ...
- **File:** ...
- **Description:** ...
- **Impact:** ...
- **Suggestion:** ...

## Unified Prioritized Roadmap

| Priority | Finding | Audit | Severity | Effort | Quick win? |
|----------|---------|-------|----------|--------|------------|

## Medium and Low Findings

[Summarized — refer to individual audit reports for full details]

| Finding | Audit | Severity | Effort |
|---------|-------|----------|--------|

## Individual Audit Reports

- Backend: `ship/audits/backend-<YYYY-MM-DD>.md`
- Database: `ship/audits/database-<YYYY-MM-DD>.md`
- Frontend: `ship/audits/frontend-<YYYY-MM-DD>.md`
- Security: `ship/audits/security-<YYYY-MM-DD>.md`
- Test Coverage: `ship/audits/tests-<YYYY-MM-DD>.md`
```

### 7. Present results to user

After writing the consolidated report:

1. Show the gate result prominently: **PASS**, **WARN**, or **FAIL**
2. List all `critical` and `high` findings with their audit source
3. Show the unified roadmap
4. If gate = FAIL: "Pipeline is blocked. Resolve critical/high findings before proceeding."
5. If gate = WARN: "Medium findings detected. Review and decide whether to proceed."
6. If gate = PASS: "All audits passed. Codebase is in good shape."

---

## Rules

- **ALWAYS launch all applicable audits in a single parallel call** — never run audits sequentially.
- **Do not skip security**: `audit:security` always runs regardless of project type.
- **Do not skip tests**: `audit:tests` always runs regardless of project type — a failure in `audit:tests` does not block the other audits from running in parallel.
- **Monorepo**: scope each backend/frontend audit to the correct workspace directory; share the security audit across all workspaces.
- **Consolidated gate is pessimistic**: a single FAIL in any audit = overall FAIL.
- **Individual reports are authoritative**: the consolidated report summarizes; individual reports have full details.
- **Language**: See @ship/patterns/language.md.
- **For project-wide diff context**: after running `/ship:audit:run`, individual pipeline phases (`/ship:perf`, `/ship:security`) still run per-task during development. Audits are for periodic project-wide health checks.
