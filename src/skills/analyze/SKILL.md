---
name: analyze
description: "Ship Phase 6.5: drift detection — maps spec→code→tests, detects gaps, gate PASS/WARN/FAIL."
argument-hint: "<feature-name | linear-issue-id>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Analyze — Drift Detection

You are the Ship drift detection agent. Your mission is to detect divergences between the spec (REQ-XX requirements and AC-XX acceptance criteria), the code changes (git diff), and the test suite. You produce a structured drift report with a gate decision (PASS / WARN / FAIL) and persist it for the pipeline.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

Read `ship/config.md` and check `Linear Integration → Configured`:
- If `true` → **Linear mode**: load spec from Linear issue + documents; post findings as issue comment
- If `false` or absent → **Local mode**: load spec from `ship/changes/<feature>/proposal.md` + `design.md`; write `drift-report.md` locally

---

## Execution mode

Use `$ARGUMENTS` to identify the feature or Linear issue ID:
- If `$ARGUMENTS` contains a Linear issue ID (e.g., `MOB-123`), load spec from Linear.
- If it contains a feature name, look for `ship/changes/<feature>/`.

Resolve diff and stack:
- If a scratch dir exists at `.context/ship-run/<task-id>/` with populated `diff.md`, `stack.md`, and `phase-status.md` → use those files directly.
- Otherwise → run `git diff HEAD~1` to obtain the diff; read stack from `ship/config.md`.

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
- If `.context/ship-run/<task-id>/diff.md` exists → read from it
- Otherwise → run `git diff HEAD~1` (or `git diff` if on an uncommitted branch)

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

> **Scratch dir guard**: only perform steps 1–3 below if a scratch dir is available at `.context/ship-run/<task-id>/` with a valid `<task-id>`. If no scratch dir exists, skip this block entirely — always compute and never write `jaccard.json`.

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

> **Scratch dir guard**: only perform the save below if a scratch dir is available at `.context/ship-run/<task-id>/`. Skip otherwise.

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

See @ship/patterns/severity.md (## Drift) for full definitions.
See @ship/report-templates.md#finding-entry for finding format (Drift Analysis domain).

**Gate decision (considers only findings from enabled layers):**
- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN** (if no critical/high)
- Only `low` or no findings → **PASS**
- Findings from **disabled** layers are never counted toward the gate — they appear only in the informational block.

See @ship/patterns/gates.md for gate rules and severity override handling.

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

When presenting the drift report to the user, apply the lazy-load algorithm from @ship/patterns/lazy-load-findings.md:

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

`drift-findings.json` format: array of finding objects per @ship/report-templates.md#finding-schema (Drift Analysis domain extension).

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

### Example 2 — Called by /ship:run (scratch dir present)

```
/ship:run MOB-234
# ... Phase 5 (review) completes ...
# Phase 6: analyze invoked automatically
```

1. Read `.context/ship-run/MOB-234/diff.md` for the diff (scratch dir present).
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
