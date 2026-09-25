---
name: ship-audit-database
description: "Ship database audit worker — project-wide DB audit, routes by engine (MongoDB / PostgreSQL / MySQL), produces structured findings + JSON summary."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Database Worker

Project-wide database-layer audit; routes by engine per `ship/config.md`.

**Input:** $ARGUMENTS (artifact language, storage mode, database type, project context from caller).

`Inventory: <path>` in the prompt → read it first and start from its relevant sections instead of running your own discovery pass, and pass the same line to every sub-agent you spawn. Absent → discover files yourself.

---

## 1. Load context + route

If caller injected `## Config`/`## Context` inline, use only that. Otherwise read `ship/config.md`: `Linear Integration → Configured` (storage mode), `Conventions → Artifact language`, `Database` (MongoDB|PostgreSQL|MySQL|SQLite|none), `Stack`.

Rule set: MongoDB → `mongodb`, PostgreSQL → `postgresql`, MySQL → `mysql`, SQLite → `sqlite` (PostgreSQL rules), unknown → `postgresql` (state the assumption in the report). `none`/unset → tell the user to set the `Database` field and stop.

---

## 2. Find

Run `bash <Heuristics script> <rule set> --out .context/ship-audit/db-heuristics.md` (the script path is in your prompt) and read the file. Every hit is a candidate: confirm it against the schema, the query's surroundings and the config before reporting it, and drop the ones that do not hold (a filter an existing index covers, an array bounded by validation elsewhere).

Then look past the rules: index coverage of the hot queries' filter/sort/join fields against the declared indexes, data-model fit (embedding vs referencing, unbounded growth), connection and transaction handling, and migrations that transform data. Server settings the repo cannot show (oplog size, WiredTiger cache, `max_connections`, buffer pool on the host) go to Blind Spots.

A long candidate list may be split by rule across up to 3 sub-agents in one Agent call, each given its slice and the `Inventory:` line.

---

## 3. Consolidate findings

Each finding: Heuristic ID `<engine>-<name>` (e.g. `mongo-write-concern`), Severity, Collection/Table `<affected>` *(before File)*, File `<file:line>`, Evidence snippet, Remediation, Effort `<Hours|Days|Weeks>`, Requires migration `<Yes|No>`. Category: `MDL|IDX|QRY|WRT|CFG|SCH|PERF`.

**Severity:** Critical = write-concern `w:0` (data-loss risk). High = missing indexes/scans/schema hurting perf under load. Medium = suboptimal config/schema, no immediate failure. Low = best-practice gaps.

---

## 4. Write report

**Local:** `ship/audits/database-<YYYY-MM-DD>.md`. **Linear:** `mcp__linear-server__save_comment`, prefix `[DB]`, label `performance`, evidence file:line+snippet, plus `Maintenance window required: <Yes|No>`.

**Sections:** Summary (counts+Gate) → Diagnosis (short overview a reader can skim before the findings) → Index Analysis by Collection/Table (existing/add/remove) → Findings (severity-ordered) → Roadmap (Priority/Finding/Category/Impact/Effort/Quick win) → Validation Metrics (Finding/Metric/Current/Target) → Best Practices Checklist → Blind Spots (Hypothesis/Why unconfirmed/How to validate). Header: `# Database Audit — <date>` + `Database: <engine>`.

---

## 5. Return JSON summary

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

Fields: `audit` type id · `gate`, `score` and `counts` exactly as the findings gate prints them · `top_findings` up to 5 most severe, empty if none · `report_path` relative path to the full report.

### Gate and score

Count your findings by severity, then run the script passed to you as `Findings gate script:`:

```bash
bash <findings-gate-script> --audit <type> --critical N --high N --medium N --low N
```

It applies `ship/config.md → Severity Overrides`, the gate rules and the A–F score (the tests audit's gate is capped at WARN), and prints `critical=`/`high=`/`medium=`/`low=`/`gate=`/`score=`. Use those values in the report and the JSON; never compute the gate or score yourself. with `audit=database` and `report_path=ship/audits/database-<YYYY-MM-DD>.md`, as the **very last content** of your response.


---

## Rules

- Entire codebase, not a diff (diff-scoped: `/ship:perf`).
- Every finding carries file:line evidence.
- Flag data-transforming migrations: "Requires migration: Yes".
- Language: caller's `Artifact language` for user-facing output; code/identifiers/paths always English.
