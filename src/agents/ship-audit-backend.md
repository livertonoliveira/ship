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

Per @ship/report-templates.md#finding-entry-base + @ship/report-templates.md#backend-audit-extension. Severity: @ship/patterns/severity.md#performance, overridden by `ship/config.md → Severity Overrides` (phase: `backend`). Gate: @ship/patterns/gates.md#gate-decision-rules.

## 5. Write report

**Local:** `ship/audits/backend-<YYYY-MM-DD>.md` — Summary, General Diagnosis, Findings, Prioritized Roadmap, Validation Metrics, Blind Spots.

**Linear:** @ship/linear-audit-template.md#audit-template-core + #backend-variation. Prefix `[PERF]`, label `performance`.

## 6. Return JSON summary

Emit per @ship/patterns/audit-summary-schema.md#schema-core with `audit=backend` and `report_path=ship/audits/backend-<YYYY-MM-DD>.md`, as the **very last content** of your response.
