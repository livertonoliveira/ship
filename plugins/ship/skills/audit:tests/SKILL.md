---
name: audit:tests
description: "Ship Audit: project-wide test coverage analysis — correlates AC/REQ from spec with existing tests using Jaccard similarity, gate PASS/WARN."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
---

<!-- IMPL-REQ-01: read Test Scope from ship/config.md to filter enabled/disabled layers -->
<!-- IMPL-REQ-02: 2-agent parallel structure — Agent A discovers AC/REQ from spec, Agent B discovers tests from codebase -->
<!-- IMPL-REQ-03: Jaccard similarity correlation (same algorithm as /ship:analyze) per enabled layer -->
<!-- IMPL-REQ-04: gate logic — HIGH findings → WARN (not FAIL); no findings → PASS -->
<!-- IMPL-REQ-05: output covers both Linear mode (linear-audit-template.md) and Local mode (ship/audits/tests-<date>.md) -->
<!-- IMPL-REQ-06: strictly read-only — must NOT create, modify, or delete any test files -->

# Ship Audit — Test Coverage

You are the Ship test coverage audit agent. Your mission is to conduct a project-wide analysis of how well the existing test suite covers the acceptance criteria (AC-XX) and requirements (REQ-XX) defined in the spec. Read `ship/config.md` for Test Scope configuration and adapt all analysis accordingly.

This audit is **strictly read-only**: do NOT create, modify, or delete any test files.

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Process

### 1. Load context

See @ship/patterns/load-artifacts.md.

Read `ship/config.md` and extract:
- `Test Scope` section: enabled/disabled status for `unit`, `integration`, `e2e` layers.
- If the `Test Scope` section is absent → treat all three layers as `enabled`.
- `Linear Integration` field to determine storage mode.

---

### 2. Launch 2 agents in parallel

Use the **Agent** tool to launch **2 agents in parallel in a SINGLE call**.

---

#### Agent A — AC/REQ Discovery from Spec

**Goal:** Extract all REQ-XX requirements and AC-XX acceptance criteria from spec documents.

**Linear mode:**
1. Call `mcp__linear-server__list_documents` to find Proposal documents linked to the project.
2. Call `mcp__linear-server__get_document` for each Proposal document.
3. Parse all lines matching `REQ-\d+` and `AC-\d+`.

**Local mode:**
1. Glob `ship/changes/**/proposal.md`.
2. Read each file and parse REQ-XX and AC-XX entries.

**Extraction rules:**
- A **requirement** matches `REQ-\d+` followed by a description (e.g., `REQ-01: User can log in via OAuth`).
- An **acceptance criterion** matches `AC-\d+` followed by a description (e.g., `AC-03: Login must complete in < 2s`).
- A **scenario** is a Gherkin `Scenario`/`Scenario Outline` tagged `@SC-\d+`, `@AC-\d+`, and one layer tag (`@unit`|`@integration`|`@e2e`). In Linear mode the full Gherkin lives in the issue body (`get_issue`); the Proposal carries only a compact Scenario Index. In Local mode it lives in the `#### Scenarios` block of `tasks.md`. Apply the **Gherkin-aware keyword extractor from `/ship:analyze`** (When+Then+Examples headers only; exclude Given/Background, Gherkin keywords, `@tags`, table pipes, `<placeholders>`). Record `{ id, ac, layer, keywords[] }`.
- If no markers are found, infer from functional requirements / acceptance criteria sections and assign IDs sequentially.
- For each item, build a keyword set: split identifier tokens (camelCase → `camel`, `case`; snake_case → `snake`, `case`; PascalCase → `Pascal`, `Case`). Lowercase all tokens.
- **Backward compatibility:** if the spec has no `@SC-\d+` scenarios, the scenario list is empty and this audit behaves exactly as before this feature (AC/REQ-only).

**Output:** Structured list of `{ id, description, keywords[] }` for each REQ-XX and AC-XX found, plus `{ id, ac, layer, keywords[] }` for each SC-XX.

---

#### Agent B — Test Discovery from Codebase

**Goal:** Discover all existing test files and extract their test names.

**Discovery globs (project-wide):**
- `**/*.test.ts`
- `**/*.spec.ts`
- `**/*.test.js`
- `**/*.spec.js`
- `**/__tests__/**/*`

Exclude `node_modules/`, `.cache/`, `dist/`, `build/` directories.

**For each test file:**
1. Extract `describe(`, `it(`, and `test(` block names/strings.
2. Determine the test layer based on file path and naming conventions:
   - Files in `__tests__/unit/`, `*.unit.test.*`, or top-level `*.test.*` → `unit`
   - Files in `__tests__/integration/`, `*.integration.test.*`, `*.e2e-spec.*` (NestJS) → `integration`
   - Files in `__tests__/e2e/`, `*.e2e.test.*`, Cypress/Playwright files → `e2e`
   - If layer is ambiguous → `unit` (conservative)
3. Check for explicit coverage markers: `TEST-REQ-XX`, `TEST-AC-XX`, or `TEST-SC-XX` in comments or test names.
4. Build a keyword set per test: split test name tokens + file path tokens. Lowercase all.

**Output:** Structured list of `{ file, layer, markers[], testNames[], keywords[] }` for each test file.

---

### 3. Correlate AC/REQ ↔ tests (per layer)

After both agents complete, run correlation for each enabled Test Scope layer.

**Algorithm:** Use the same Jaccard similarity algorithm as `/ship:analyze` to compute confidence scores. Reference `.claude/commands/ship/analyze.md` for the exact algorithm.

**Confidence assignment per AC/REQ item:**

| Condition | Confidence |
|-----------|-----------|
| Explicit marker `TEST-AC-XX` or `TEST-REQ-XX` found in a test in this layer | 1.0 |
| Jaccard similarity >= 0.5 between AC keywords and any test keywords in this layer | 0.5–1.0 (proportional) |
| Jaccard similarity 0.3–0.49 | 0.3–0.49 (uncertain) |
| No test match (Jaccard < 0.3) | 0.0 |

**Scenario → test correlation:** apply the SC→test tier from `/ship:analyze` Step 3 for each `SC-XX`, evaluating **only the single layer named in its `@layer` tag** (1.0 if `TEST-SC-XX` marker; 0.8 if a `TEST-AC`/`TEST-REQ` marker for its parent AC; else Jaccard within that layer). Skip the scenario tier entirely if the spec has no `@SC-XX`.

**Layer handling:**
- **Enabled layer:** run full correlation; produce findings per uncovered/uncertain AC and per uncovered/uncertain SC.
- **Disabled layer:** mark all ACs and SCs as `disabled (not evaluated)` — do NOT produce findings; does not affect gate.

**Finding classification (enabled layers only):**

| Condition | Severity |
|-----------|----------|
| Confidence = 0.0 (uncovered AC **or SC** in enabled layer) | HIGH |
| Confidence 0.3–0.49 (uncertain coverage in enabled layer) | MEDIUM |
| Confidence >= 0.5 | No finding — covered |

Produce findings per @ship/report-templates.md#finding-entry with the Test Coverage domain extensions (Layer, Current confidence, Effort).

---

### 4. Write report

**Local mode:** Write to `ship/audits/tests-<YYYY-MM-DD>.md`

**Linear mode:** See @ship/linear-audit-template.md. Use prefix `[TEST]`, label `test-coverage`, and apply the Tests Coverage category variation (includes AC/REQ Evidence fields and Fix snippet).

**Report format:**

```markdown
# Test Coverage Audit — <YYYY-MM-DD>

## Summary
- Total ACs: X
- Covered (≥0.5): X (XX%)
- Uncertain (0.3–0.49): X
- Uncovered (0.0): X
- Total Scenarios: X  <!-- omit these 4 SC lines if the spec has no @SC-XX -->
- Scenarios covered (≥0.5): X (XX%)
- Scenarios uncertain (0.3–0.49): X
- Scenarios uncovered (0.0): X
- Layers evaluated: unit | integration | e2e
- Layers skipped (disabled): <layer> | none
- **Gate: PASS | WARN**

## Test Scope Configuration
| Layer | Status |
|-------|--------|
| unit | enabled / disabled |
| integration | enabled / disabled |
| e2e | enabled / disabled |

## Coverage by Layer

### Unit
| AC / REQ | Description | Confidence | Test File | Status |
|----------|-------------|-----------|-----------|--------|
| AC-01 | <desc> | 1.0 | path/to/file.test.ts | covered |
| AC-02 | <desc> | 0.0 | — | UNCOVERED |

#### Scenarios (unit)
<Omit this sub-table when the spec has no @SC-XX scenarios for this layer.>
| SC | AC | Description | Confidence | Test File | Status |
|----|----|-------------|-----------|-----------|--------|
| SC-01 | AC-01 | <scenario name> | 1.0 | path/to/file.test.ts | covered |
| SC-02 | AC-01 | <scenario name> | 0.0 | — | UNCOVERED |

### Integration
[same table format, including the per-layer Scenarios sub-table]

### E2E
[same table format, including the per-layer Scenarios sub-table]

## Findings

[findings ordered by severity — HIGH first, then MEDIUM]

## Prioritized Recommendations

| Priority | AC / REQ | Layer | Confidence | Recommended Action |
|----------|----------|-------|-----------|-------------------|
| 1 | AC-02 | unit | 0.0 | Add unit test verifying <description> |

## Blind Spots

| Hypothesis | Why unconfirmed | What to collect |
|------------|----------------|-----------------|
```

See @ship/patterns/gates.md for gate reference.

**Gate rules for this audit (override standard gate):**
- HIGH findings (uncovered ACs in enabled layers) → **WARN** (not FAIL — test gaps are a quality issue, not a blocking defect)
- MEDIUM findings only → **WARN**
- No findings → **PASS**

> Note: This audit intentionally uses WARN (not FAIL) for HIGH findings. Uncovered acceptance criteria represent a quality gap to be addressed, not a pipeline-blocking vulnerability.

### Return JSON summary

After writing the report, output the following JSON block as the **very last content** of your tool result. `ship:audit:run` reads this directly from the agent result — no file re-read needed.

See @ship/patterns/audit-summary-schema.md for field definitions and scoring table.

> **Note:** Gate for this audit is capped at `PASS|WARN` — never `FAIL`. The `score` field follows the standard scoring table but `F` is not applicable here.

```json
{
  "audit": "tests",
  "gate": "<PASS|WARN>",
  "score": "<A|B|C|D>",
  "counts": {"critical": 0, "high": 0, "medium": 0, "low": 0},
  "top_findings": [
    {"id": "<ID>", "severity": "<high|medium>", "title": "<title>", "file": "<file:line>"}
  ],
  "report_path": "ship/audits/tests-<YYYY-MM-DD>.md"
}
```

---

## Rules

- **Entire codebase scope**: project-wide audit — scans all test files, not just a diff. For diff-scoped analysis, use `/ship:analyze`.
- **Read-only**: do NOT create, modify, or delete any test files or source files.
- **Test Scope respected**: disabled layers are informational only and do not affect gate.
- **Evidence required**: cite file and test name for every covered AC; cite absence of match for every uncovered AC.
- **Jaccard reference**: use the algorithm from `/ship:analyze` (`.claude/commands/ship/analyze.md`). Do not reimplement independently.
- **HIGH → WARN (not FAIL)**: this audit uses a softer gate than security/backend audits. Uncovered scenarios (SC-XX) follow the same HIGH→WARN cap.
- **Scenario backward compatibility**: detection is presence-based. No `@SC-XX` in the spec → omit all scenario rows/sub-tables and behave exactly as before this feature. Never fabricate scenarios.
- **ALWAYS launch 2 agents in parallel** — never sequentially. Single Agent tool call.
- **Language**: See @ship/patterns/language.md.
- For diff-scoped coverage analysis during the pipeline, use `/ship:analyze`.
