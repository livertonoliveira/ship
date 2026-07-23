---
name: ship-audit-tests
description: "Ship Audit: project-wide test coverage worker — correlates AC/REQ from spec with existing tests using Jaccard similarity, gate PASS/WARN."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Test Coverage Worker

Project-wide, read-only audit correlating spec AC/REQ/SC against the test suite via Jaccard similarity; never modifies test/source files. Read `ship/config.md` for storage mode, language, Test Scope (absent = all enabled). Input: $ARGUMENTS.

## 1. Launch 2 agents in parallel (one Agent call)

**Agent A — spec discovery:** REQ-XX/AC-XX plus Gherkin `@SC-XX`/`@layer` scenarios from Linear docs/issues, or local `proposal.md`/`tasks.md`; no markers → infer sequentially.

**Agent B — code discovery:** glob test/spec files (excl. node_modules/dist/build); extract test names, classify layer by path/naming (ambiguous → unit), keyword-tokenize names+paths. Keyword-only — no marker scanning.

## 2. Correlate and gate

Per enabled layer, Jaccard similarity; confidence >=0.5 covered, 0.3-0.49 uncertain, <0.3 uncovered. Scenarios use the same tier scoped to `@layer`; skip if none. Disabled layers → `disabled`, no gate impact. Findings: 0.0 → HIGH, 0.3-0.49 → MEDIUM, else none — per `### Base Template {#finding-entry-base}

```markdown
### [SEVERITY] <Descriptive Title>
- **Category:** <domain-specific — see extensions below>
- **File:** <path>:<line>
- **Description:** <what the problem is>
- **Impact:** <estimated impact>
- **Suggestion:** <specific fix with code example if helpful>
```

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md).` + `#### Tests audit (`audit/tests.md`) {#tests-audit-extension}

Category: `TEST`
```markdown
- **Layer:** <unit | integration | e2e>                                # adds
- **Current confidence:** <0.0–1.0>                                    # adds
- **Closest test match:** <path or none>                               # adds
- **Effort:** <Hours | Days>                                           # adds
- **Suggestion:** <Fix snippet — example test that would cover the AC/SC>  # specializes Suggestion
```

---`.

Gate per `## Gate Decision Rules {#gate-decision-rules}

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

> See `worker-status.md` for the orthogonal completion axis (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED) — a worker's completion state is independent of the PASS/WARN/FAIL gate result documented here.` + `## Schema Core {#schema-core}

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

`A` none/only-low · `B` no critical/high, ≥1 medium · `C` no critical, 1–2 high · `D` no critical, 3+ high · `F` ≥1 critical.`: **uncovered ACs/SCs (HIGH) map to WARN only, never FAIL** — a quality gap, not a blocking defect. MEDIUM-only → WARN; none → PASS.

## 3. Report

Sections: Summary, Test Scope, Coverage by Layer, Findings, Recommendations, Blind Spots. **Local:** `ship/audits/tests-<date>.md`. **Linear:** `## Core Template {#audit-template-core}

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
```` + `### Tests Coverage (`audit/tests.md`) {#tests-variation}

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
  ````, prefix `[TEST]`, label `test-coverage`. Emit summary JSON per `the Schema Core section (included above)`.

## Rules

Project-wide only. Cite evidence: file+test, or absence. Never fabricate scenarios. Storage isolation enforced both ways. User text in `Artifact language`; code/paths stay English.
