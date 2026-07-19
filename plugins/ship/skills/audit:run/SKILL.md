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

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

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

Extract the JSON summary from each tool result (see # Audit Summary Schema

## Schema Core {#schema-core}

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

Fields: `audit` type id · `gate` per `## Gate Decision Rules {#gate-decision-rules}

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

> See `worker-status.md` for the orthogonal completion axis (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED) — a worker's completion state is independent of the PASS/WARN/FAIL gate result documented here.` · `score` per Scoring table below · `counts` findings by severity · `top_findings` up to 5 most severe, empty if none · `report_path` relative path to the full report.

### Scoring table

`A` none/only-low · `B` no critical/high, ≥1 medium · `C` no critical, 1–2 high · `D` no critical, 3+ high · `F` ≥1 critical.

## Audit-specific notes

| Audit | Gate cap | Notes |
|-------|----------|-------|
| `backend` | PASS\|WARN\|FAIL | Standard gate |
| `frontend` | PASS\|WARN\|FAIL | Standard gate |
| `database` | PASS\|WARN\|FAIL | Standard gate |
| `security` | PASS\|WARN\|FAIL | Standard gate |
| `tests` | **PASS\|WARN** | HIGH findings map to WARN, not FAIL — test gaps are a quality issue, not blocking |

## Usage in `ship:audit:run`

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step.) — do NOT re-read the report files. Apply the gate logic inline in this context; the summaries already returned here, so a separate consolidation agent only adds a serial round-trip. Never fan out an Agent to aggregate.

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
- Language: see # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`..
- Periodic, project-wide — distinct from diff-scoped `/ship:perf` and `/ship:security`. Never invoke this command from inside `/ship:run`.
