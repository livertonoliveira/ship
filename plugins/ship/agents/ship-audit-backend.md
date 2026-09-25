---
name: ship-audit-backend
description: "Ship audit worker — project-wide backend performance audit. Confirms script-scanned candidates (queries, locks, I/O, memory, network, secrets in logs), looks past them, and produces a structured findings report."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Backend Performance Worker

Project-wide backend performance audit (not diff-scoped). **Input:** $ARGUMENTS (artifact language, storage mode, stack, team ID).

`Inventory: <path>` in the prompt → read it first and start from its relevant sections instead of running your own discovery pass, and pass the same line to every sub-agent you spawn. Absent → discover files yourself.

## 1. Load context

Read `ship/config.md` (or inline `## Config`/`## Stack`) for Linear Integration, Artifact language, stack, Team ID.

## 2. Pre-flight

If `Project Type` is `frontend`, redirect the user to `/ship:audit:frontend` and stop.

## 3. Find

Run `bash <Heuristics script> backend --out .context/ship-audit/backend-heuristics.md` (the script path is in your prompt) and read the file. It lists candidates for N+1 queries, uncached read routes, pessimistic locks, blocking I/O, unbounded in-memory caches, requests without a timeout and secrets in logs. Confirm each against its surroundings before reporting it and drop the ones that do not hold.

Then look past the rules across the backend tree: hot paths doing redundant work, missing pagination on growing collections, lock and transaction scope, retry/backoff on outbound calls, and anything else with measurable latency, throughput or memory impact. Every finding carries file:line evidence.

A long candidate list may be split across up to 3 sub-agents in one Agent call, each given its slice and the `Inventory:` line.

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

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md). + #### Backend audit (`ship-audit-backend`) {#backend-audit-extension}

Categories: `DB | NET | CPU | MEM | CONC | CODE | CONF | ARCH`
```markdown
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Maintenance window:** <Yes | No>                                   # adds
```. Severity: ## Performance {#performance}

- **critical**: Will cause visible performance degradation in production (e.g., N+1 on every request, full table scan on large table)
- **high**: Likely to cause issues under load (e.g., missing pagination on growing dataset)
- **medium**: Suboptimal but will not cause immediate issues (e.g., missing cache on moderately accessed data)
- **low**: Best practice not followed, marginal impact (e.g., synchronous logging in low-traffic endpoint). Gate and score: the findings gate (see the JSON summary section).

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

Fields: `audit` type id · `gate`, `score` and `counts` exactly as the findings gate prints them · `top_findings` up to 5 most severe, empty if none · `report_path` relative path to the full report.

### Gate and score

Count your findings by severity, then run the script passed to you as `Findings gate script:`:

```bash
bash <findings-gate-script> --audit <type> --critical N --high N --medium N --low N
```

It applies `ship/config.md → Severity Overrides`, the gate rules and the A–F score (the tests audit's gate is capped at WARN), and prints `critical=`/`high=`/`medium=`/`low=`/`gate=`/`score=`. Use those values in the report and the JSON; never compute the gate or score yourself. with `audit=backend` and `report_path=ship/audits/backend-<YYYY-MM-DD>.md`, as the **very last content** of your response.
