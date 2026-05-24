---
name: analyze
description: "Ship Phase 6.5: drift detection — maps spec→code→tests, detects gaps, gate PASS/WARN/FAIL."
argument-hint: "<feature-name | linear-issue-id>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Analyze — Drift Detection

You are the Ship drift detection agent. Your mission is to detect divergences between the spec (REQ-XX requirements and AC-XX acceptance criteria), the code changes (git diff), and the test suite. You produce a structured drift report with a gate decision (PASS / WARN / FAIL) and persist it for the pipeline.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

Read `ship/config.md` and check `Linear Integration → Configured`:
- If `true` → **Linear mode**: load spec from Linear issue + documents; post findings as issue comment
- If `false` or absent → **Local mode**: load spec from `ship/changes/<feature>/proposal.md` + `design.md`; write `drift-report.md` locally

---

## Execution mode

Determine how you were invoked:

- **Pipeline mode** (invoked by `/ship:run` Phase 6): Read scratch dir at `.context/ship-run/<task-id>/`. Context files are already populated: `diff.md`, `stack.md`, `phase-status.md`. The task ID is passed in `$ARGUMENTS` or via environment.
- **Standalone mode** (invoked directly via `/ship:analyze`): Use `$ARGUMENTS` to identify the feature or Linear issue ID. If `$ARGUMENTS` contains a Linear issue ID (e.g., `MOB-123`), load spec from Linear. If it contains a feature name, look for `ship/changes/<feature>/`. If neither resolves, run `git diff HEAD~1` to obtain the diff.

---

## Process

### 1. Load spec

**Goal:** Extract all REQ-XX requirements and AC-XX acceptance criteria from the spec documents.

**Linear mode:**
1. Call `mcp__linear-server__get_issue` with the issue ID to get the task details.
2. Call `mcp__linear-server__list_documents` to find the Proposal and Design documents linked to the project.
3. Call `mcp__linear-server__get_document` for the Proposal document → parse all lines matching `REQ-\d+` and `AC-\d+`.
4. Call `mcp__linear-server__get_document` for the Design document → extract additional context for each requirement.

**Local mode:**
1. Read `ship/changes/<feature>/proposal.md` → parse REQ-XX and AC-XX entries.
2. Read `ship/changes/<feature>/design.md` → extract additional context.

**Test Scope loading (both modes):**
1. Read `ship/config.md` → locate the `Test Scope` section.
2. Extract the enabled/disabled status for each layer: `unit`, `integration`, `e2e`.
3. If the `Test Scope` section is absent → treat all three layers as `enabled`.
4. Store the result as `test_scope` context (e.g., `{ unit: enabled, integration: disabled, e2e: disabled }`) for use in Step 3.

**Extraction rules:**
- A **requirement** is any line or block matching `REQ-\d+` followed by a description (e.g., `REQ-01: User authentication via OAuth`).
- An **acceptance criterion** is any line or block matching `AC-\d+` followed by a description (e.g., `AC-03: Login must complete in < 2s`).
- If no REQ-XX or AC-XX markers are found, infer them from the proposal's functional requirements and acceptance criteria sections and assign IDs sequentially.
- A **scenario** is a Gherkin `Scenario` / `Scenario Outline` in the issue/task `## Scenarios` block, tagged `@SC-\d+`, `@AC-\d+`, and exactly one layer tag (`@unit` | `@integration` | `@e2e`). In Linear mode the full Gherkin lives in the **issue body** (already fetched via `get_issue`); the Proposal carries only a compact Scenario Index — parse `SC-XX` from the issue, not the index. In Local mode parse it from the task `#### Scenarios` block in `tasks.md`.
  - Record per scenario: `sc.id`, `sc.ac` (parent AC-YY), `sc.layer`.
  - **Gherkin-aware keyword set (critical for Jaccard signal):** from each scenario, take ONLY the `When` and `Then` step text plus any `Examples` column headers. **Exclude** the `Given`/`Background` steps (state setup = noise), all Gherkin keywords (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), every `@tag`, table `|` pipes, and `<placeholder>` angle brackets. Then tokenize the remaining identifiers the same way as code (camelCase/snake_case/PascalCase → lowercased tokens).
- **Backward compatibility:** if the spec contains no `@SC-\d+` scenarios at all, the scenario tier is empty and analyze behaves exactly as before this feature (AC-only correlation).

---

### 2. Extract code and tests

**Goal:** Parse the diff to identify changed files, functions, and classes; discover test files in the workspace.

**Diff source:**
- Pipeline mode: read `.context/ship-run/<task-id>/diff.md`
- Standalone mode: run `git diff HEAD~1` (or `git diff` if on an uncommitted branch)

**Code extraction:**
1. Parse the diff to list all changed files (added, modified, deleted).
2. For each file, extract changed function/class/method names from the diff hunks.
3. Build a keyword set per file: split identifiers into tokens (camelCase → `camel`, `Case`; snake_case → `snake`, `case`; PascalCase → `Pascal`, `Case`). Lowercase all tokens.

**Test extraction:**
1. Detect workspace from diff file paths:
   - Monorepo prefixes: `apps/`, `packages/`, `services/`, `libs/`, `modules/`
   - If a prefix is found, restrict discovery to that workspace subtree.
   - If no prefix found: search the full repository.
2. Glob for test files: `**/*.test.ts`, `**/*.spec.ts`, `**/*.test.js`, `**/*.spec.js`, `**/__tests__/**/*.ts`, `**/__tests__/**/*.js` (adapt extensions to the detected stack).
3. For each test file, extract: test names (strings in `it(`, `test(`, `describe(` blocks) and build a keyword set.

**Override marker detection:**
- Scan all changed source files for comments containing `IMPL-REQ-\d+` or `IMPL-SC-\d+` (e.g., `// IMPL-REQ-05`, `// IMPL-SC-12`).
- Scan all test files for comments containing `TEST-REQ-\d+`, `TEST-AC-\d+`, or `TEST-SC-\d+` (e.g., `// TEST-REQ-03`, `// TEST-AC-03`, `// TEST-SC-08`).
- Record these markers — they bypass keyword matching in Step 3.

---

### Parallel Execution — Steps 1 and 2

Use the **Agent tool** to run Steps 1 and 2 concurrently. Send both agent invocations in a **single message** (two tool uses). Do not wait for one to finish before starting the other.

- **Agent A** — Spec loading (Step 1 above)
- **Agent B** — Code and test extraction (Step 2 above)

Both agents write their results to the scratch dir or return them inline. Step 3 (correlation) starts only after BOTH agents complete.

---

### 3. Correlate spec ↔ code ↔ tests

**Goal:** Map each requirement to code files (implementation confidence) and each criterion to test files (coverage confidence).

**Jaccard cache check (before computing):**

> **Pipeline mode guard**: only perform steps 1–3 below if a scratch dir is available (i.e., you were invoked in pipeline mode with a valid `<task-id>`). In standalone mode (no scratch dir), skip this block entirely — always compute and never write `jaccard.json`.

1. Compute `diff_hash`: SHA-256 of the full diff content (read from `diff.md` or the inline diff string).
2. Compute `spec_hash`: SHA-256 of the concatenated spec text — all REQ-XX and AC-XX descriptions **followed by every `@SC-XX` scenario block (heading + When + Then + Examples + layer tag)**, in order. Including the scenario blocks is correctness-critical: editing a scenario without touching its AC must invalidate the cache.
3. Check if `.context/ship-run/<task-id>/jaccard.json` exists:
   - If it exists: attempt to parse it as JSON.
     - If parsing **fails** (corrupted or truncated file) → treat as cache miss, compute normally (continue below).
     - If parsing succeeds: compare stored `diff_hash` and `spec_hash` against the computed values.
       - If **both match** → use the cached `matrix` directly. Skip all Jaccard computations below and proceed to Step 4 with the cached matrix.
       - If **either differs** → discard cache and compute normally (continue below).
   - If it **does not exist** → compute normally (continue below).

**Requirement → code mapping (keyword Jaccard similarity):**

For each `REQ-XX`:
1. If `IMPL-REQ-XX` marker found in any code file → set confidence = 1.0 (skip matching).
2. Otherwise:
   - Build the requirement keyword set: tokenize the REQ-XX description.
   - For each changed file's keyword set: compute Jaccard similarity = `|intersection| / |union|`.
   - Best match confidence = highest Jaccard score across all files.
   - Best match file = the file with the highest score.

**Criterion → test mapping (keyword matching with Test Scope filtering):**

Classify test files by layer before matching:
- **unit**: files matching `*.test.*`, `*.spec.*`, `__tests__/**` that do NOT match integration or e2e patterns below.
- **integration**: files matching `*.integration.test.*`, `*.integration.spec.*`, or located under `__tests__/integration/`.
- **e2e**: files matching `*.e2e.*`, `*.e2e-spec.*`, or located under `e2e/`, `cypress/`, or `playwright/`.

For each `AC-XX`, for each test layer (`unit`, `integration`, `e2e`):
1. If the layer is **disabled** in `test_scope` → do NOT emit a finding for missing coverage in this layer. Instead, record the AC-ID in `informational_disabled_layers[layer]` (e.g., `{ integration: [AC-03, AC-07], e2e: [AC-01, AC-03] }`). Skip all further matching for this layer.
2. If the layer is **enabled** in `test_scope`:
   a. If `TEST-REQ-XX` or `TEST-AC-XX` marker found in any test file for this layer → set test confidence = 1.0 (skip matching).
   b. Otherwise:
      - Build the criterion keyword set: tokenize the AC-XX description.
      - For each test file in this layer's keyword set: compute Jaccard similarity.
      - Layer confidence = highest Jaccard score across all files in this layer.

Overall AC coverage confidence: use the **best match across ALL enabled layers only**.

**Scenario → test mapping (per scenario, only its tagged layer):**

Skip this tier entirely if the spec has no `@SC-\d+` scenarios. Otherwise, for each `SC-XX` evaluate **only the single layer named in its `@layer` tag** (the scenario already declares its owning layer — this is more precise than the AC heuristic across all layers):

1. If that layer is **disabled** in `test_scope` → do NOT emit a finding. Record the SC-ID in `informational_disabled_layers[layer]` alongside any ACs. Skip further matching for this scenario.
2. If the layer is **enabled**:
   a. If a `TEST-SC-XX` marker is found in any test file in this layer → scenario confidence = 1.0.
   b. Else if a `TEST-AC-YY` or `TEST-REQ` marker for this scenario's parent AC (`sc.ac`) is found in this layer → scenario confidence = 0.8 (AC-level coverage gives partial credit; scenario-specificity is unverified). This preserves backward compatibility for teams already using AC markers.
   c. Otherwise: Jaccard between the scenario's Gherkin-aware keyword set (When+Then+Examples headers) and each test file's keyword set in this layer. Scenario confidence = highest score in this layer.

**Jaccard cache save (after computing):**

> **Pipeline mode guard**: only perform the save below if you are in pipeline mode (scratch dir available). Skip in standalone mode.

After all Jaccard computations complete (this block is skipped if the cache was reused above), write `.context/ship-run/<task-id>/jaccard.json`:

```json
{
  "diff_hash": "<sha256 of diff content>",
  "spec_hash": "<sha256 of concatenated spec text>",
  "matrix": {
    "REQ-01": { "code": ["src/foo.ts:10"], "score": 0.7 },
    "AC-01":  { "tests": ["test/foo.test.ts:42"], "score": 0.9 },
    "SC-01":  { "tests": ["test/foo.test.ts:42"], "score": 0.9, "layer": "unit", "ac": "AC-01" }
  }
}
```

> **Edge case — all layers disabled:** if `unit`, `integration`, and `e2e` are all `disabled`, no TEST-category findings are emitted. All ACs land in `informational_disabled_layers`. The gate evaluates only IMPL/DRIFT findings (REQ-XX). This is intentional — the behavior mirrors what `/ship:test` does when all layers are disabled.

**Confidence interpretation:**
- Confidence = 0 → not found (unimplemented / uncovered)
- 0 < confidence < 0.5 → uncertain match (low confidence)
- confidence ≥ 0.5 → implemented / tested

---

### 4. Generate report

**Goal:** Build a structured markdown drift report with per-requirement and per-criterion status, gap summaries, and a gate decision.

**Findings classification:**

| Severity | Condition | Category |
|----------|-----------|----------|
| critical | REQ-XX has confidence = 0 (zero code matches) | IMPL |
| high | REQ-XX has 0 < confidence < 0.5 (uncertain) | DRIFT |
| medium | AC-XX has confidence = 0 (zero test matches) | TEST |
| medium | SC-XX has confidence = 0 in its tagged enabled layer | SCENARIO |
| low | AC-XX has 0 < confidence < 0.5 (uncertain) | DRIFT |
| low | SC-XX has 0 < confidence < 0.5 (uncertain) | DRIFT |

See # Severity Definitions

## Performance

- **critical**: Will cause visible performance degradation in production (e.g., N+1 on every request, full table scan on large table)
- **high**: Likely to cause issues under load (e.g., missing pagination on growing dataset)
- **medium**: Suboptimal but will not cause immediate issues (e.g., missing cache on moderately accessed data)
- **low**: Best practice not followed, marginal impact (e.g., synchronous logging in low-traffic endpoint)

## Security

- **critical**: Remote exploitation without authentication, unrestricted access to sensitive data. Requires immediate fix.
- **high**: Exploitation possible with authentication or specific conditions. Significant impact risk.
- **medium**: Hard to exploit but relevant impact, or easy to exploit with limited impact.
- **low**: Theoretical risk, defense-in-depth, or best practice not followed.

## Code Review

- **critical**: Architectural issue that will cause significant problems if not addressed (e.g., circular dependency, broken abstraction that leaks implementation details across the entire system)
- **high**: Significant design issue that will make the code hard to maintain/extend (e.g., god class, tight coupling between modules)
- **medium**: Code smell that should be addressed but does not block (e.g., duplicated logic, overly complex conditional)
- **low**: Minor improvement opportunity (e.g., naming could be clearer, slightly long function)

## Frontend

Uses Core Web Vitals thresholds:

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| LCP | ≤ 2.5s | 2.5s – 4.0s | > 4.0s |
| INP | ≤ 200ms | 200ms – 500ms | > 500ms |
| CLS | ≤ 0.1 | 0.1 – 0.25 | > 0.25 |
| FCP | ≤ 1.8s | 1.8s – 3.0s | > 3.0s |
| TTFB | ≤ 800ms | 800ms – 1800ms | > 1800ms |

- **critical**: Core Web Vital in "Poor" range; severely impacting UX or conversion
- **high**: Core Web Vital in "Needs Improvement"; measurable impact on bounce/conversion
- **medium**: Relevant technical inefficiency, no immediate critical impact
- **low**: Incremental optimization, good for backlog

## Database

- **critical**: Causes active production degradation, data risk, or imminent failure as data grows
- **high**: Significant performance degradation that worsens with data growth
- **medium**: Relevant inefficiency, no immediate critical impact
- **low**: Best practice not followed, marginal impact

## Drift (Spec ↔ Code ↔ Test conformance)

| Severity | Definition | Examples |
|----------|-----------|---------|
| critical | Requirement has zero code matches (confidence = 0) — completely unimplemented | REQ-05 not found anywhere in diff |
| high | Requirement has low confidence match (0 < confidence < 0.5) — implementation uncertain | REQ-03 found in loosely related file, confidence 0.2 |
| medium | Acceptance criterion has zero test matches — criterion not tested | AC-07 not covered by any test |
| medium | Scenario has zero test matches in its tagged enabled layer — scenario not tested | SC-09 (@integration) not covered by any test |
| low | Acceptance criterion has low confidence test match — coverage uncertain | AC-12 mentioned in unrelated test, confidence 0.1 |
| low | Scenario has low confidence test match — coverage uncertain | SC-04 loosely matched, confidence 0.2 |

### Override Markers

To assert known-correct coverage and bypass keyword matching:
- `IMPL-REQ-XX` in source code → forces requirement confidence to 1.0 (implemented)
- `IMPL-SC-XX` in source code → hint that a scenario's behavior lives in divergently-named code (does not by itself prove a test exists)
- `TEST-REQ-XX` / `TEST-AC-XX` in test file → forces criterion confidence to 1.0 (tested); grants child scenarios 0.8 partial credit
- `TEST-SC-XX` in test file → forces scenario `SC-XX` confidence to 1.0 (tested)

Use override markers when requirement names don't match code naming conventions (e.g., spec says "cache invalidation" but code uses "eviction").

## Severity Overrides

Before applying standard gate rules (`critical|high → fail`, `medium → warn`), check if `ship/config.md` contains a `## Severity Overrides` section. If present, apply matching overrides before evaluating the gate.

### Format

```
## Severity Overrides
- <phase>: <from-severity>→<to-severity>
```

Where `<phase>` must be one of the valid pipeline phases: `dev`, `test`, `perf`, `security`, `review`, `frontend-perf`, `database`, `backend`.

### How to apply

1. Read all entries under `## Severity Overrides` in `ship/config.md`.
2. For each finding in the current phase, check if an override matches (`phase` + `from-severity`).
3. If matched, replace the finding's effective severity with `to-severity` before the gate decision.
4. Apply standard gate rules to the (possibly overridden) effective severities.

### Validation

If an override entry references an unknown phase (not in the valid phase list above), emit an error and stop:

```
Severity override refers to unknown phase: <phase-name>
```

Do not silently ignore unknown phase overrides — fail fast to prevent misconfiguration.

### Examples

**Example 1 — Downgrade perf high to warn**

Config:
```
## Severity Overrides
- perf: high→warn
```

Effect: A `high` finding in the `perf` phase becomes effective severity `warn` (medium gate level). Gate decision: WARN instead of FAIL.

**Example 2 — Downgrade frontend-perf high to warn**

Config:
```
## Severity Overrides
- frontend-perf: high→warn
```

Effect: LCP "Needs Improvement" findings (`high`) in the `frontend-perf` phase generate a WARN gate instead of FAIL. Security, review, and other phases are unaffected.

**Example 3 — Multiple overrides**

Config:
```
## Severity Overrides
- perf: high→warn
- security: medium→low
```

Effect: `high` perf findings → WARN gate; `medium` security findings → treated as `low` (PASS if no other critical/high). Each phase applies only its own override. (## Drift) for full definitions.
See # Ship — Report Templates

Canonical source for all reporting templates used across Ship command files.
Import by reference: `See ship/report-templates.md#<anchor>`.

---

## Finding Entry {#finding-entry}

Base template. All domains share this structure.

```markdown
### [SEVERITY] <Descriptive Title>
- **Category:** <domain-specific — see extensions below>
- **File:** <path>:<line>
- **Description:** <what the problem is>
- **Impact:** <estimated impact>
- **Suggestion:** <specific fix with code example if helpful>
```

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md).

### Domain extensions

Fields that **replace or add to** the base template per domain:

**Performance pipeline** (`perf.md`) — categories: `DB | ALGO | MEM | NET | BUNDLE | RENDER | ARCH`
> No extra fields. Uses base template as-is.

**Security pipeline** (`security.md`) — categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639 Authorization Bypass Through User-Controlled Key>  # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker would gain>                            # keeps (same field, specific guidance)
- **Proof of Concept:** <example malicious request/payload when applicable>  # adds
- **Fix:** <specific code change with example>                         # replaces Suggestion
```

**Code Review pipeline** (`review.md`) — categories: `SOLID-S | SOLID-O | SOLID-L | SOLID-I | SOLID-D | DRY | KISS | CLEAN | CONSISTENCY | TEST`
```markdown
- **Principle:** <SOLID-* | DRY | KISS | CLEAN | CONSISTENCY | TEST>  # replaces Category
- **Problem:** <what's wrong and why it matters>                      # replaces Description
```

**Frontend audit** (`audit/frontend.md`) — categories: `NET | BUNDLE | LOAD | RENDER | JS | HYDRAT | IMG | FONT | MEM | 3P | ARCH`
(Next.js: `STRATEGY | BOUNDARY | CACHE | BUNDLE | STREAMING | IMG | FONT | MIDDLEWARE | BUILD | COLD | ARCH`)
```markdown
- **Metric affected:** LCP | INP | CLS | FCP | TTFB | TBT | First Load JS | Bundle size  # adds
- **Effort:** <Hours | Days | Weeks>                                   # adds
```

**Backend audit** (`audit/backend.md`) — categories: `DB | NET | CPU | MEM | CONC | CODE | CONF | ARCH`
```markdown
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Maintenance window:** <Yes | No>                                   # adds
```

**Security audit** (`audit/security.md`) — categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC | DEPS | PRIV`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639>                                            # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker or data breach would yield>            # keeps
- **Proof of Concept:** <example malicious request/payload for critical/high findings>  # adds
- **Fix:** <specific code change with example using the project's patterns>  # replaces Suggestion
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Urgent deploy:** <Yes | No>                                        # adds
```

**Database audit** (`audit/database.md`) — categories: `MDL | IDX | QRY | WRT | CFG | SCH | PERF`
```markdown
- **Collection/Table:** <name(s) affected>                             # adds (before File)
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Requires migration:** <Yes | No>                                   # adds
```

---

## Finding JSON Schema {#finding-schema}

Base schema. Applies to all domains.

```json
{
  "severity": "critical|high|medium|low",
  "category": "<domain-specific>",
  "filePath": "src/path/to/file.ts",
  "line": 42,
  "title": "...",
  "description": "...",
  "suggestion": "..."
}
```

### Schema extensions by domain

**Security pipeline / Security audit** — additional fields:
```json
{
  "owasp": "A03:2021 Injection",
  "cwe": "CWE-89"
}
```

**Frontend audit** — additional fields:
```json
{
  "metricAffected": "LCP|INP|CLS|FCP|TTFB|TBT|First Load JS|Bundle size",
  "effort": "Hours|Days|Weeks"
}
```

**Backend audit** — additional fields:
```json
{
  "effort": "Hours|Days|Weeks",
  "maintenanceWindow": true
}
```

**Database audit** — additional fields:
```json
{
  "collectionOrTable": "<name>",
  "effort": "Hours|Days|Weeks",
  "requiresMigration": true
}
```

---

## Drift Analysis Findings {#drift-findings}

Used by `/ship:analyze` phase. Extends the base Finding Entry with drift-specific fields.

### Finding Entry Format

| Field | Type | Description |
|-------|------|-------------|
| Severity | critical \| high \| medium \| low | See severity.md — Drift domain |
| Category | IMPL \| TEST \| SCENARIO \| DRIFT | IMPL = implementation gap, TEST = AC test coverage gap, SCENARIO = scenario coverage gap, DRIFT = low-confidence match |
| File | path or — | Source file where the issue was detected |
| Description | string | What is missing or mismatched |
| Suggestion | string | How to fix: implement the req, add a test, or add an override marker |
| Requirement ID | REQ-XX or — | Linked requirement, if applicable |
| Criterion ID | AC-XX or — | Linked acceptance criterion, if applicable |
| Scenario ID | SC-XX or — | Linked scenario, if applicable |
| Layer | unit \| integration \| e2e or — | Scenario's tagged test layer (SCENARIO findings only) |

### Severity Mapping

| Severity | Trigger | Gate Impact |
|----------|---------|-------------|
| critical | Requirement with 0 code matches | FAIL |
| high | Requirement confidence < 0.5 | FAIL |
| medium | Acceptance criterion with 0 test matches | WARN |
| medium | Scenario with 0 test matches in its tagged enabled layer | WARN |
| low | Criterion or scenario confidence < 0.5 | PASS |

### Example Reports

#### PASS
`✓ Análise de Drift: PASS (0 gaps) — [ver relatório completo](link)`

#### WARN (medium findings)
```
### [MEDIUM] Critério sem cobertura de teste: AC-03
- **Categoria:** TEST
- **Descrição:** O critério de aceitação "AC-03" não possui testes identificados.
- **Sugestão:** Crie um teste para o critério AC-03 ou adicione o marcador TEST-AC-03.
```

#### FAIL (critical findings)
```
### [CRITICAL] Requisito não implementado: REQ-05
- **Categoria:** IMPL
- **Descrição:** O requisito "REQ-05: Cache invalidation" não possui implementação identificada.
- **Sugestão:** Implemente o requisito REQ-05 ou adicione o marcador IMPL-REQ-05 no arquivo.
```

### JSON Schema

```json
{
  "severity": "critical | high | medium | low",
  "category": "IMPL | TEST | DRIFT",
  "title": "string",
  "description": "string",
  "suggestion": "string",
  "requirementId": "REQ-XX | null",
  "criterionId": "AC-XX | null",
  "filePath": "string | null",
  "line": "number | null"
}
```

---

## Quality Report {#quality-report}

Consolidated from `homolog.md`. Used in both Linear mode (as issue comment) and Local mode (as `report-<task-id>.md`).

Each findings section is rendered using the lazy-load algorithm — see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`.

```markdown
# Quality Report — <Feature / Task Title>

## Summary
| Phase | Gate | Critical | High | Medium | Low |
|-------|------|----------|------|--------|-----|
| Performance | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Security | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Code Review | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |

## Performance Findings
<!-- gate = PASS: one-line summary only -->
✓ Performance: PASS (0 critical/high findings) — [see full report](<link or path>)

<!-- gate = WARN or FAIL: critical/high/medium in full; low aggregated -->
### [HIGH] <Title>
<finding in Finding Entry format>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ 3 low-severity findings — [see full report](<link or path>)

## Security Findings
<!-- same lazy-load pattern as Performance -->

## Code Review Findings
<!-- same lazy-load pattern as Performance -->

## Fixes Applied
<list of fixes applied automatically during the pipeline, or "None.">

## Homologation
- [ ] User has reviewed all changes
- [ ] User has verified acceptance criteria
- [ ] User approves for PR
```

---

## Acceptance Report {#acceptance-report}

Consolidated from `homolog.md`. Presented to the user during the acceptance phase.

```markdown
## Acceptance Report — <Feature / Task Title>

### What was implemented
<3-5 bullet points summarizing what was built>

### Technical decisions
<Key decisions from the Design document>

### Tests
- Unit tests: X created, all passing
- Integration tests: Y created, all passing
- E2E tests: Z created (or "not applicable")

### Quality Gates
| Phase | Status | Details |
|-------|--------|---------|
| Performance | PASS / WARN / FAIL | X findings |
| Security | PASS / WARN / FAIL | X findings |
| Code Review | PASS / WARN / FAIL | X findings |

### Pending warnings
<Medium-level findings accepted by the user, or "None.">

### Acceptance criteria — Manual verification
<From the issue/proposal — for the user to check off>
- [ ] Criterion 1
- [ ] Criterion 2
```

---

## PR Body Template {#pr-body}

Extracted from `pr.md`. Used by `/ship:pr` to build the pull request description via `gh pr create`.

```markdown
## Summary
<From Proposal: why this change was made — 2-3 sentences>

## Changes
<From Design: architecture overview + key technical decisions>

### Files Changed
<From Design: files created and modified>

## Test Results
| Type | Count | Status |
|------|-------|--------|
| Unit | <n> | Passing |
| Integration | <n> | Passing |
| E2E | <n> | Passing / N/A |

## Quality Report
<!-- lazy-load algorithm: see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md` -->

### Summary
| Phase | Gate | Critical | High | Medium | Low |
|-------|------|----------|------|--------|-----|
| Performance | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Security | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Code Review | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |

### Performance Findings
<!-- gate = PASS: one-line summary only -->
✓ Performance: PASS (0 critical/high findings) — [see full report](<link or path>)

<!-- gate = WARN or FAIL: critical/high/medium in full; low aggregated -->

### Security Findings
<!-- same lazy-load pattern as Performance -->

### Code Review Findings
<!-- same lazy-load pattern as Performance -->

## Test Plan
<From acceptance criteria — for PR reviewer to verify>
- [ ] Criterion 1
- [ ] Criterion 2

---
Generated by **Ship** | Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Lazy Mode {#lazy-mode}

Canonical rendering format for per-phase findings in quality reports and PR descriptions.
For the decision algorithm (how to determine PASS / WARN / FAIL), see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`.

### Gate = PASS — tabela-resumo

When a phase gate = PASS, emit only the compact summary table row. **No findings content is embedded.**

Format:

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

Single-phase inline variant (used inside phase subsections):

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

**Example — all phases PASS:**

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

### Gate = WARN or FAIL — bloco expandido

When a phase gate = WARN or FAIL, embed findings inline. Apply the filter:
- **Include in full**: all findings with severity `critical`, `high`, or `medium`
- **Aggregate**: replace all `low` findings with a single count line

Format:

```
### [HIGH] <Title>
<finding in Finding Entry format — see #finding-entry>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ N low-severity findings — [see full report](<link or path>)
```

**Example — Security gate = FAIL:**

### [HIGH] SQL Injection in search endpoint
- **Category:** INJ
- **File:** src/routes/search.ts:34
- **Description:** User input is interpolated directly into a raw SQL query without parameterization.
- **Impact:** Full database read/write access for an attacker.
- **Suggestion:** Use parameterized queries via the ORM or prepared statements.

### [MEDIUM] Missing rate limiting on login route
- **Category:** CFG
- **File:** src/routes/auth.ts:12
- **Description:** The POST /login endpoint has no rate limit, enabling brute-force attacks.
- **Impact:** Credential enumeration and account takeover.
- **Suggestion:** Apply a rate-limiting middleware (e.g., express-rate-limit) with a 5-attempts/minute threshold.

+ 3 low-severity findings — [see full report](https://linear.app/mobitech/issue/MOB-XXXX)

---

## Report Summary Table {#report-summary}

Compact summary block used at the end of `/ship:perf`, `/ship:security`, `/ship:review`, and all `/ship:audit:*` reports.

```markdown
## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**
```#finding-entry for finding format (Drift Analysis domain).

**Gate decision (considers only findings from enabled layers):**
- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN** (if no critical/high)
- Only `low` or no findings → **PASS**
- Findings from **disabled** layers are never counted toward the gate — they appear only in the informational block.

See # Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

Before launching the parallel quality phases (perf / security / review), the orchestrator captures a snapshot of the current HEAD commit. This snapshot is used by the PR agent to build the diff and, when auto-fix is applied, to decide which phases to re-run.

**When it is captured:** step 0.5 of `run.md` — during scratch-dir initialization, before any quality agent starts.

**File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`

**Format:** single line containing the SHA from `git rev-parse HEAD` (no trailing newline required).

**When it is read:**
- By the PR agent (`pr.md`) to build the diff between the snapshot and the final HEAD.
- By the orchestrator after auto-fix to determine which phases to re-run (controlled by `on_fail_rerun`).

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Read `pre-quality-snapshot.sha` from scratch dir
2. Run `git diff --name-only <sha> HEAD` to get modified files from the fix
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** `git diff --name-only <sha> HEAD` returns empty after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, `git diff --name-only` returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4. for gate rules and severity override handling.

**Report format:**

```markdown
# Drift Analysis Report — <Feature / Task Title>

## Summary
| Metric | Value |
|--------|-------|
| Requirements analyzed | N |
| Requirements implemented (≥ 0.5) | N |
| Requirements uncertain (< 0.5) | N |
| Requirements unimplemented (= 0) | N |
| Criteria analyzed | N |
| Criteria covered (≥ 0.5) | N |
| Criteria uncertain (< 0.5) | N |
| Criteria uncovered (= 0) | N |
| Scenarios analyzed | N |
| Scenarios covered (≥ 0.5) | N |
| Scenarios uncovered (= 0) | N |
| **Gate** | PASS / WARN / FAIL |

> The three `Scenarios …` rows appear only when the spec contains `@SC-XX` scenarios. Omit them entirely for legacy scenario-free specs.

## Requirements Status

| ID | Description | Confidence | File | Status |
|----|-------------|------------|------|--------|
| REQ-01 | <description> | 0.85 | src/auth/login.ts | ✓ Implemented |
| REQ-02 | <description> | 0.30 | src/utils/helpers.ts | ⚠ Uncertain |
| REQ-03 | <description> | 0.00 | — | ✗ Unimplemented |

## Criteria Status

| ID | Description | Test Confidence | Test File | Status |
|----|-------------|-----------------|-----------|--------|
| AC-01 | <description> | 0.90 | src/auth/login.test.ts | ✓ Covered |
| AC-02 | <description> | 0.40 | src/utils/helpers.test.ts | ⚠ Uncertain |
| AC-03 | <description> | 0.00 | — | ✗ Uncovered |

## Scenarios Status

<Omit this entire section for legacy specs with no @SC-XX scenarios.>

| ID | AC | Layer | Description | Test Confidence | Test File | Status |
|----|----|-------|-------------|-----------------|-----------|--------|
| SC-01 | AC-01 | unit | <scenario name> | 1.00 | src/auth/login.test.ts | ✓ Covered |
| SC-02 | AC-01 | unit | <scenario name> | 0.40 | src/auth/login.test.ts | ⚠ Uncertain |
| SC-03 | AC-02 | integration | <scenario name> | 0.00 | — | ✗ Uncovered |

## Gaps

### [CRITICAL] Requisito não implementado: REQ-03
- **Categoria:** IMPL
- **Descrição:** O requisito "REQ-03: <description>" não possui implementação identificada no diff.
- **Sugestão:** Implemente o requisito REQ-03 ou adicione o marcador `IMPL-REQ-03` no arquivo correspondente.
- **Requirement ID:** REQ-03

### [HIGH] Implementação incerta: REQ-02
- **Categoria:** DRIFT
- **Arquivo:** src/utils/helpers.ts
- **Descrição:** O requisito "REQ-02" possui correspondência com baixa confiança (0.30). A implementação pode estar incompleta ou mal nomeada.
- **Sugestão:** Verifique se `src/utils/helpers.ts` implementa REQ-02 corretamente, ou adicione o marcador `IMPL-REQ-02`.
- **Requirement ID:** REQ-02

### [MEDIUM] Critério sem cobertura de teste: AC-03
- **Categoria:** TEST
- **Descrição:** O critério de aceitação "AC-03: <description>" não possui testes identificados.
- **Sugestão:** Crie um teste para o critério AC-03 ou adicione o marcador `TEST-AC-03`.
- **Criterion ID:** AC-03

### [MEDIUM] Cenário sem cobertura: SC-03
- **Categoria:** SCENARIO
- **Camada:** integration
- **Descrição:** O cenário "SC-03 → AC-02: <scenario name>" não possui teste identificado na camada `integration`.
- **Sugestão:** Crie um teste para o cenário SC-03 ou adicione o marcador `TEST-SC-03` no teste correspondente.
- **Scenario ID:** SC-03
- **Criterion ID:** AC-02

## Disabled Layers — Informational (does not affect gate)

The layers below are disabled in `Test Scope` and were not evaluated.
To audit coverage for these layers, run `/ship:audit:run`.

| Layer | ACs / SCs not evaluated |
|-------|-----------------|
| integration | AC-03, AC-07, SC-03 |
| e2e | AC-01, AC-03, AC-05, AC-07, SC-09 |

> This section appears **only** when `informational_disabled_layers` is non-empty (i.e., at least one AC-XX or SC-XX was recorded for a disabled layer). Omit entirely if all layers are enabled or `informational_disabled_layers` is empty.

## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**
```

**Lazy-load rendering (user-facing output):**

When presenting the drift report to the user, apply the lazy-load algorithm from ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`:

- **Gate = PASS**: emit a single summary line — do NOT embed findings:
  ```
  ✓ Drift Analysis: PASS (0 gaps) — [ver relatório completo](<link or scratch dir path>)
  ```
- **Gate = WARN or FAIL**: embed all `critical`, `high`, and `medium` findings in full (using the format from `## Gaps` above). Replace ALL `low` findings with a single aggregated line:
  ```
  + N achados de severidade baixa — [ver relatório completo](<link or scratch dir path>)
  ```

The full `drift-report.md` (with all findings) is always persisted to the scratch dir. The lazy-load rendering applies only to the **user-facing output** and to the Linear comment (if Linear mode).

---

### 5. Persist results

**Scratch dir (always):**
- Write `drift-report.md` to `.context/ship-run/<task-id>/drift-report.md`
- Write `drift-findings.json` to `.context/ship-run/<task-id>/drift-findings.json`

`drift-findings.json` format: array of finding objects per # Ship — Report Templates

Canonical source for all reporting templates used across Ship command files.
Import by reference: `See ship/report-templates.md#<anchor>`.

---

## Finding Entry {#finding-entry}

Base template. All domains share this structure.

```markdown
### [SEVERITY] <Descriptive Title>
- **Category:** <domain-specific — see extensions below>
- **File:** <path>:<line>
- **Description:** <what the problem is>
- **Impact:** <estimated impact>
- **Suggestion:** <specific fix with code example if helpful>
```

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md).

### Domain extensions

Fields that **replace or add to** the base template per domain:

**Performance pipeline** (`perf.md`) — categories: `DB | ALGO | MEM | NET | BUNDLE | RENDER | ARCH`
> No extra fields. Uses base template as-is.

**Security pipeline** (`security.md`) — categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639 Authorization Bypass Through User-Controlled Key>  # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker would gain>                            # keeps (same field, specific guidance)
- **Proof of Concept:** <example malicious request/payload when applicable>  # adds
- **Fix:** <specific code change with example>                         # replaces Suggestion
```

**Code Review pipeline** (`review.md`) — categories: `SOLID-S | SOLID-O | SOLID-L | SOLID-I | SOLID-D | DRY | KISS | CLEAN | CONSISTENCY | TEST`
```markdown
- **Principle:** <SOLID-* | DRY | KISS | CLEAN | CONSISTENCY | TEST>  # replaces Category
- **Problem:** <what's wrong and why it matters>                      # replaces Description
```

**Frontend audit** (`audit/frontend.md`) — categories: `NET | BUNDLE | LOAD | RENDER | JS | HYDRAT | IMG | FONT | MEM | 3P | ARCH`
(Next.js: `STRATEGY | BOUNDARY | CACHE | BUNDLE | STREAMING | IMG | FONT | MIDDLEWARE | BUILD | COLD | ARCH`)
```markdown
- **Metric affected:** LCP | INP | CLS | FCP | TTFB | TBT | First Load JS | Bundle size  # adds
- **Effort:** <Hours | Days | Weeks>                                   # adds
```

**Backend audit** (`audit/backend.md`) — categories: `DB | NET | CPU | MEM | CONC | CODE | CONF | ARCH`
```markdown
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Maintenance window:** <Yes | No>                                   # adds
```

**Security audit** (`audit/security.md`) — categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC | DEPS | PRIV`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639>                                            # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker or data breach would yield>            # keeps
- **Proof of Concept:** <example malicious request/payload for critical/high findings>  # adds
- **Fix:** <specific code change with example using the project's patterns>  # replaces Suggestion
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Urgent deploy:** <Yes | No>                                        # adds
```

**Database audit** (`audit/database.md`) — categories: `MDL | IDX | QRY | WRT | CFG | SCH | PERF`
```markdown
- **Collection/Table:** <name(s) affected>                             # adds (before File)
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Requires migration:** <Yes | No>                                   # adds
```

---

## Finding JSON Schema {#finding-schema}

Base schema. Applies to all domains.

```json
{
  "severity": "critical|high|medium|low",
  "category": "<domain-specific>",
  "filePath": "src/path/to/file.ts",
  "line": 42,
  "title": "...",
  "description": "...",
  "suggestion": "..."
}
```

### Schema extensions by domain

**Security pipeline / Security audit** — additional fields:
```json
{
  "owasp": "A03:2021 Injection",
  "cwe": "CWE-89"
}
```

**Frontend audit** — additional fields:
```json
{
  "metricAffected": "LCP|INP|CLS|FCP|TTFB|TBT|First Load JS|Bundle size",
  "effort": "Hours|Days|Weeks"
}
```

**Backend audit** — additional fields:
```json
{
  "effort": "Hours|Days|Weeks",
  "maintenanceWindow": true
}
```

**Database audit** — additional fields:
```json
{
  "collectionOrTable": "<name>",
  "effort": "Hours|Days|Weeks",
  "requiresMigration": true
}
```

---

## Drift Analysis Findings {#drift-findings}

Used by `/ship:analyze` phase. Extends the base Finding Entry with drift-specific fields.

### Finding Entry Format

| Field | Type | Description |
|-------|------|-------------|
| Severity | critical \| high \| medium \| low | See severity.md — Drift domain |
| Category | IMPL \| TEST \| SCENARIO \| DRIFT | IMPL = implementation gap, TEST = AC test coverage gap, SCENARIO = scenario coverage gap, DRIFT = low-confidence match |
| File | path or — | Source file where the issue was detected |
| Description | string | What is missing or mismatched |
| Suggestion | string | How to fix: implement the req, add a test, or add an override marker |
| Requirement ID | REQ-XX or — | Linked requirement, if applicable |
| Criterion ID | AC-XX or — | Linked acceptance criterion, if applicable |
| Scenario ID | SC-XX or — | Linked scenario, if applicable |
| Layer | unit \| integration \| e2e or — | Scenario's tagged test layer (SCENARIO findings only) |

### Severity Mapping

| Severity | Trigger | Gate Impact |
|----------|---------|-------------|
| critical | Requirement with 0 code matches | FAIL |
| high | Requirement confidence < 0.5 | FAIL |
| medium | Acceptance criterion with 0 test matches | WARN |
| medium | Scenario with 0 test matches in its tagged enabled layer | WARN |
| low | Criterion or scenario confidence < 0.5 | PASS |

### Example Reports

#### PASS
`✓ Análise de Drift: PASS (0 gaps) — [ver relatório completo](link)`

#### WARN (medium findings)
```
### [MEDIUM] Critério sem cobertura de teste: AC-03
- **Categoria:** TEST
- **Descrição:** O critério de aceitação "AC-03" não possui testes identificados.
- **Sugestão:** Crie um teste para o critério AC-03 ou adicione o marcador TEST-AC-03.
```

#### FAIL (critical findings)
```
### [CRITICAL] Requisito não implementado: REQ-05
- **Categoria:** IMPL
- **Descrição:** O requisito "REQ-05: Cache invalidation" não possui implementação identificada.
- **Sugestão:** Implemente o requisito REQ-05 ou adicione o marcador IMPL-REQ-05 no arquivo.
```

### JSON Schema

```json
{
  "severity": "critical | high | medium | low",
  "category": "IMPL | TEST | DRIFT",
  "title": "string",
  "description": "string",
  "suggestion": "string",
  "requirementId": "REQ-XX | null",
  "criterionId": "AC-XX | null",
  "filePath": "string | null",
  "line": "number | null"
}
```

---

## Quality Report {#quality-report}

Consolidated from `homolog.md`. Used in both Linear mode (as issue comment) and Local mode (as `report-<task-id>.md`).

Each findings section is rendered using the lazy-load algorithm — see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`.

```markdown
# Quality Report — <Feature / Task Title>

## Summary
| Phase | Gate | Critical | High | Medium | Low |
|-------|------|----------|------|--------|-----|
| Performance | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Security | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Code Review | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |

## Performance Findings
<!-- gate = PASS: one-line summary only -->
✓ Performance: PASS (0 critical/high findings) — [see full report](<link or path>)

<!-- gate = WARN or FAIL: critical/high/medium in full; low aggregated -->
### [HIGH] <Title>
<finding in Finding Entry format>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ 3 low-severity findings — [see full report](<link or path>)

## Security Findings
<!-- same lazy-load pattern as Performance -->

## Code Review Findings
<!-- same lazy-load pattern as Performance -->

## Fixes Applied
<list of fixes applied automatically during the pipeline, or "None.">

## Homologation
- [ ] User has reviewed all changes
- [ ] User has verified acceptance criteria
- [ ] User approves for PR
```

---

## Acceptance Report {#acceptance-report}

Consolidated from `homolog.md`. Presented to the user during the acceptance phase.

```markdown
## Acceptance Report — <Feature / Task Title>

### What was implemented
<3-5 bullet points summarizing what was built>

### Technical decisions
<Key decisions from the Design document>

### Tests
- Unit tests: X created, all passing
- Integration tests: Y created, all passing
- E2E tests: Z created (or "not applicable")

### Quality Gates
| Phase | Status | Details |
|-------|--------|---------|
| Performance | PASS / WARN / FAIL | X findings |
| Security | PASS / WARN / FAIL | X findings |
| Code Review | PASS / WARN / FAIL | X findings |

### Pending warnings
<Medium-level findings accepted by the user, or "None.">

### Acceptance criteria — Manual verification
<From the issue/proposal — for the user to check off>
- [ ] Criterion 1
- [ ] Criterion 2
```

---

## PR Body Template {#pr-body}

Extracted from `pr.md`. Used by `/ship:pr` to build the pull request description via `gh pr create`.

```markdown
## Summary
<From Proposal: why this change was made — 2-3 sentences>

## Changes
<From Design: architecture overview + key technical decisions>

### Files Changed
<From Design: files created and modified>

## Test Results
| Type | Count | Status |
|------|-------|--------|
| Unit | <n> | Passing |
| Integration | <n> | Passing |
| E2E | <n> | Passing / N/A |

## Quality Report
<!-- lazy-load algorithm: see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md` -->

### Summary
| Phase | Gate | Critical | High | Medium | Low |
|-------|------|----------|------|--------|-----|
| Performance | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Security | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |
| Code Review | PASS/WARN/FAIL | 0 | 0 | 0 | 0 |

### Performance Findings
<!-- gate = PASS: one-line summary only -->
✓ Performance: PASS (0 critical/high findings) — [see full report](<link or path>)

<!-- gate = WARN or FAIL: critical/high/medium in full; low aggregated -->

### Security Findings
<!-- same lazy-load pattern as Performance -->

### Code Review Findings
<!-- same lazy-load pattern as Performance -->

## Test Plan
<From acceptance criteria — for PR reviewer to verify>
- [ ] Criterion 1
- [ ] Criterion 2

---
Generated by **Ship** | Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

---

## Lazy Mode {#lazy-mode}

Canonical rendering format for per-phase findings in quality reports and PR descriptions.
For the decision algorithm (how to determine PASS / WARN / FAIL), see ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`.

### Gate = PASS — tabela-resumo

When a phase gate = PASS, emit only the compact summary table row. **No findings content is embedded.**

Format:

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

Single-phase inline variant (used inside phase subsections):

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

**Example — all phases PASS:**

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

### Gate = WARN or FAIL — bloco expandido

When a phase gate = WARN or FAIL, embed findings inline. Apply the filter:
- **Include in full**: all findings with severity `critical`, `high`, or `medium`
- **Aggregate**: replace all `low` findings with a single count line

Format:

```
### [HIGH] <Title>
<finding in Finding Entry format — see #finding-entry>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ N low-severity findings — [see full report](<link or path>)
```

**Example — Security gate = FAIL:**

### [HIGH] SQL Injection in search endpoint
- **Category:** INJ
- **File:** src/routes/search.ts:34
- **Description:** User input is interpolated directly into a raw SQL query without parameterization.
- **Impact:** Full database read/write access for an attacker.
- **Suggestion:** Use parameterized queries via the ORM or prepared statements.

### [MEDIUM] Missing rate limiting on login route
- **Category:** CFG
- **File:** src/routes/auth.ts:12
- **Description:** The POST /login endpoint has no rate limit, enabling brute-force attacks.
- **Impact:** Credential enumeration and account takeover.
- **Suggestion:** Apply a rate-limiting middleware (e.g., express-rate-limit) with a 5-attempts/minute threshold.

+ 3 low-severity findings — [see full report](https://linear.app/mobitech/issue/MOB-XXXX)

---

## Report Summary Table {#report-summary}

Compact summary block used at the end of `/ship:perf`, `/ship:security`, `/ship:review`, and all `/ship:audit:*` reports.

```markdown
## Summary
- Critical: X
- High: X
- Medium: X
- Low: X
- **Gate: PASS | WARN | FAIL**
```#finding-schema (Drift Analysis domain extension).

**Linear mode:**
- Post the drift report summary as a comment on the task issue via `mcp__linear-server__save_comment`.
- Comment format: one-line gate result + collapsible full report block.
- Do NOT write `drift-report.md` to `ship/changes/` in Linear mode.

**Local mode:**
- Write `drift-report.md` to `ship/changes/<feature>/drift-report.md`.

**Append to `phase-status.md`** (pipeline mode):

Append a row to `.context/ship-run/<task-id>/phase-status.md`:

```
| analyze | <run#> | <ISO-timestamp> | <total-reqs+criteria> | <gate> | <critical> | <high> | <medium> | <low> | <notes> |
```

---

## Rules

1. **Always read `ship/config.md` first** to determine storage mode before loading any artifacts. Never assume Linear or Local mode.

2. **Parallelism**: Steps 1 (spec loading) and 2 (code/test extraction) MUST run in parallel using the Agent tool. Do not run them sequentially.

3. **Confidence thresholds**: confidence ≥ 0.5 = implemented/tested; 0 < confidence < 0.5 = uncertain; confidence = 0 = unimplemented/uncovered.

4. **IMPL-REQ-XX / IMPL-SC-XX override**: if `IMPL-REQ-XX` is found in any source file in the diff, set confidence = 1.0 for REQ-XX without keyword matching. `IMPL-SC-XX` is an optional hint that the scenario's behavior lives in code whose naming diverges — it does not by itself prove a test exists. This is the canonical way to assert known-correct implementation when naming conventions diverge.

5. **TEST-XX override**: if `TEST-REQ-XX`, `TEST-AC-XX`, or `TEST-SC-XX` is found in any test file, set test confidence = 1.0 for the corresponding item. `TEST-SC-XX` forces scenario `SC-XX` to 1.0. A `TEST-AC-YY`/`TEST-REQ` marker for a scenario's parent AC grants that scenario **0.8** partial credit (not 1.0) — scenario-specificity is unverified. Same rationale as IMPL-REQ-XX.

6. **Gate enforcement**: gate FAIL → pipeline blocks before `homolog`; gate WARN → pipeline pauses and asks the user before continuing; gate PASS → continue to `homolog`. Respect `on_fail` and `on_warn` settings from `ship/config.md → Gate Behavior`.

7. **Monorepo awareness**: detect the active workspace from diff path prefixes (`apps/`, `packages/`, `services/`, `libs/`, `modules/`). Restrict test discovery and file matching to that workspace. If no workspace prefix is found, analyze the full repo.

8. **Storage isolation**: Linear mode → never create local files outside the scratch dir; Local mode → never call Linear API tools.

9. **Test Scope awareness**: Before emitting any coverage finding (category: TEST or SCENARIO), check whether the test layer is enabled in `ship/config.md → Test Scope`. For SCENARIO findings the relevant layer is the scenario's own `@layer` tag. Disabled layers never generate MEDIUM/WARN findings — they appear only in the informational block (`## Disabled Layers — Informational`). If `Test Scope` is absent from config, treat all layers as enabled (preserve existing behavior).

10. **Scenario backward compatibility**: detection is presence-based. If the spec has no `@SC-XX` scenarios, skip the scenario tier entirely, omit the Scenarios Status table and the three Scenario summary rows, and behave exactly as before this feature. Never infer or fabricate scenarios.

---

## Examples

### Example 1 — Standalone with Linear issue

```
/ship:analyze MOB-234
```

1. Read `ship/config.md` → Linear mode confirmed.
2. Load spec from Linear issue MOB-234 and its Proposal document.
3. Run `git diff HEAD~1` to get the diff (no scratch dir available).
4. Run Steps 1 and 2 in parallel.
5. Correlate, generate report, post as comment on MOB-234.
6. Print gate result to the user.

---

### Example 2 — Pipeline mode (called by /ship:run)

```
/ship:run MOB-234
# ... Phase 5 (review) completes ...
# Phase 6: analyze invoked automatically
```

1. Read `.context/ship-run/MOB-234/diff.md` for the diff.
2. Read `.context/ship-run/MOB-234/stack.md` for stack context.
3. Load spec from Linear (or local, based on config).
4. Run Steps 1 and 2 in parallel.
5. Write `drift-report.md` and `drift-findings.json` to scratch dir.
6. Post to Linear (or write locally).
7. Append row to `phase-status.md`.
8. Return gate result to `run.md` orchestrator.

---

### Example 3 — Override markers in code

Spec contains:
```
REQ-07: Cache invalidation on entity update
```

Code uses `eviction` instead of `invalidation`:
```typescript
// IMPL-REQ-07
function evictCacheOnUpdate(entityId: string) { ... }
```

Test uses:
```typescript
// TEST-SC-07
it('should evict cache when entity is updated', () => { ... })
```

Result: REQ-07 gets confidence = 1.0 (IMPL-REQ-07 marker found). SC-07 gets scenario confidence = 1.0 (TEST-SC-07 marker found); its parent AC is covered transitively. No gaps reported for REQ-07 or SC-07.
