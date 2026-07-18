---
name: ship-audit-backend
description: "Ship audit worker — project-wide backend performance audit. Launches 3 parallel agents (DB+Cache+Locks, I/O+Memory, Network+Security-Adjacent) and produces a structured findings report."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Backend Performance Worker

Project-wide backend performance audit (not diff-scoped). **Input:** $ARGUMENTS (artifact language, storage mode, stack, team ID).

## 1. Load context

Read `ship/config.md` (or inline `## Config`/`## Stack`) for Linear Integration, Artifact language, stack, Team ID.

## 2. Pre-flight

If `Project Type` is `frontend`, redirect the user to `/ship:audit:frontend` and stop.

## 3. Launch 3 agents in parallel (one Agent call), scanning the whole backend tree:

**Agent A — DB/Cache/Locks**
- **A1** N+1 Queries (Medium): async loop (`.forEach(async`/`.map(async`) awaiting `find/query/save` calls inside → prefetch/batch with `Promise.all` or eager-load relations.
- **A2** Missing Cache (Low): GET route on shared/read-heavy resource with no `Cache-Control`/`@CacheKey` → add caching directive/middleware.
- **A3** Pessimistic Locks (Medium): `FOR UPDATE` lacking `NOWAIT`/`SKIP LOCKED`/timeout, or outside an explicit transaction → add lock timeout and wrap in transaction.

**Agent B — I/O/Memory**
- **B1** Blocking I/O (Medium): sync fs/exec calls (`readFileSync`, `execSync`, etc.) inside an async context → use async equivalents (`fs.promises.*`, promisified exec).
- **B2** Memory Growth (Medium): module-level `Map`/`Set` with no eviction (`.delete`/`.clear`/LRU) anywhere in file → bound with an LRU cache or periodic eviction.

**Agent C — Network/Security-Adjacent**
- **C1** Request Timeout (Medium): `axios`/`fetch` call with no `timeout`/`AbortController`/`AbortSignal.timeout` → add a timeout.
- **C2** Secret Leaks (High): log call near a variable named password/token/secret/apiKey/credential → redact or drop from the log.

## 4. Consolidate findings

Per ### Base Template {#finding-entry-base}

```markdown
### [SEVERITY] <Descriptive Title>
- **Category:** <domain-specific — see extensions below>
- **File:** <path>:<line>
- **Description:** <what the problem is>
- **Impact:** <estimated impact>
- **Suggestion:** <specific fix with code example if helpful>
```

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md). + #### Backend audit (`audit/backend.md`) {#backend-audit-extension}

Categories: `DB | NET | CPU | MEM | CONC | CODE | CONF | ARCH`
```markdown
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Maintenance window:** <Yes | No>                                   # adds
```. Severity: ## Performance {#performance}

- **critical**: Will cause visible performance degradation in production (e.g., N+1 on every request, full table scan on large table)
- **high**: Likely to cause issues under load (e.g., missing pagination on growing dataset)
- **medium**: Suboptimal but will not cause immediate issues (e.g., missing cache on moderately accessed data)
- **low**: Best practice not followed, marginal impact (e.g., synchronous logging in low-traffic endpoint), overridden by `ship/config.md → Severity Overrides` (phase: `backend`). Gate: ## Gate Decision Rules {#gate-decision-rules}

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

> See `worker-status.md` for the orthogonal completion axis (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED) — a worker's completion state is independent of the PASS/WARN/FAIL gate result documented here..

## 5. Write report

**Local:** `ship/audits/backend-<YYYY-MM-DD>.md` — Summary, General Diagnosis, Findings, Prioritized Roadmap, Validation Metrics, Blind Spots.

**Linear:** ## Core Template {#audit-template-core}

### Steps {#audit-template-steps}

Apply in **Linear mode** (`ship/config.md → Linear Integration: yes`) after generating the audit report. **Local mode**: write to `ship/audits/<type>-<YYYY-MM-DD>.md` instead.

Team/Project fields below always come from `ship/config.md → Linear Integration → Team ID` / the project created in step 1. "Per variation" means see [Category variations](#category-variations) for this audit type's specific value.

1. **Project** — `mcp__linear-server__save_project`: Name `<Audit Type> — <YYYY-MM-DD>`, Team, Description per variation (app name, stack context, gate result + findings count, one-sentence top issue). **Never reuse an existing project** — always create a new one per run.
2. **Report document** — `mcp__linear-server__save_document`: Title `<Audit Type> — <YYYY-MM-DD>`, Project, Content = full report markdown.
3. **Milestones** — `mcp__linear-server__save_milestone`, one per severity with ≥1 finding (skip empty ones): "Critical Fixes" / "High Fixes" / "Medium Fixes" / "Low Fixes". Team, Project.
4. **Issues per finding** — `mcp__linear-server__save_issue` for every finding at any severity: Title `[PREFIX] <title>` (prefix per variation), Team, Project, Priority Urgent|High|Medium|Low matching severity, Labels = primary label per variation + `severity` label, Milestone from step 3, Description = base template below (unless the variation fully replaces it) extended with the variation's category-specific fields.

### Base Template {#audit-template-base}
```markdown
## Problem
<Evidence from code, cite file:line.>

## Impact
<Estimated impact — latency, memory, security, data integrity.>

## Evidence
- **File:** <path>:<line>
- **Code:** <snippet>

## Fix
<Specific fix with a code example.>

## Acceptance Criteria
- [ ] <Verifiable criterion>
- [ ] No regressions in related tests

## Notes
- **Effort:** <Hours | Days | Weeks>
``` + #backend-variation. Prefix `[PERF]`, label `performance`.

## 6. Return JSON summary

Emit per ## Schema Core {#schema-core}

Each `ship:audit:*` agent outputs this JSON as the **last content** of its tool result (`ship:audit:run` reads it directly — no file I/O).

### Schema

```json
{
  "audit": "<backend|frontend|database|security|tests>",
  "gate": "<PASS|WARN|FAIL>",
  "score": "<A|B|C|D|F>",
  "counts": { "critical": 0, "high": 0, "medium": 0, "low": 0 },
  "top_findings": [{ "id": "<FINDING-ID>", "severity": "<critical|high|medium|low>", "title": "<short title>", "file": "<path/to/file.ts:line>" }],
  "report_path": "ship/audits/<type>-<YYYY-MM-DD>.md"
}
```

Fields: `audit` type id · `gate` per `the Gate Decision Rules section (included above)` · `score` per Scoring table below · `counts` findings by severity · `top_findings` up to 5 most severe, empty if none · `report_path` relative path to the full report.

### Scoring table

`A` none/only-low · `B` no critical/high, ≥1 medium · `C` no critical, 1–2 high · `D` no critical, 3+ high · `F` ≥1 critical. with `audit=backend` and `report_path=ship/audits/backend-<YYYY-MM-DD>.md`, as the **very last content** of your response.
