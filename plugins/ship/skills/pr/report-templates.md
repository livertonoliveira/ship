# Ship — Report Templates

Canonical source for all reporting templates used across Ship command files.
Import by reference: `See ship/report-templates.md#<anchor>`.

---

## Finding Entry {#finding-entry}

Base template. All domains share this structure.

### Base Template {#finding-entry-base}

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

Fields that **replace or add to** the base template per domain. Each consumer pulls `#finding-entry-base` plus only its own domain's extension below.

#### Performance pipeline (`perf.md`) {#perf-extension}

Categories: `DB | ALGO | MEM | NET | BUNDLE | RENDER | ARCH`. No extra fields — uses base template as-is.

#### Security pipeline (`security.md`) {#security-pipeline-extension}

Categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639 Authorization Bypass Through User-Controlled Key>  # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker would gain>                            # keeps (same field, specific guidance)
- **Proof of Concept:** <example malicious request/payload when applicable>  # adds
- **Fix:** <specific code change with example>                         # replaces Suggestion
```

#### Code Review pipeline (`review.md`) {#review-extension}

Categories: `SOLID-S | SOLID-O | SOLID-L | SOLID-I | SOLID-D | DRY | KISS | CLEAN | CONSISTENCY | TEST`
```markdown
- **Principle:** <SOLID-* | DRY | KISS | CLEAN | CONSISTENCY | TEST>  # replaces Category
- **Problem:** <what's wrong and why it matters>                      # replaces Description
```

#### Frontend audit (`audit/frontend.md`) {#frontend-audit-extension}

Categories: `NET | BUNDLE | LOAD | RENDER | JS | HYDRAT | IMG | FONT | MEM | 3P | ARCH`
(Next.js: `STRATEGY | BOUNDARY | CACHE | BUNDLE | STREAMING | IMG | FONT | MIDDLEWARE | BUILD | COLD | ARCH`)
```markdown
- **Metric affected:** LCP | INP | CLS | FCP | TTFB | TBT | First Load JS | Bundle size  # adds
- **Effort:** <Hours | Days | Weeks>                                   # adds
```

#### Backend audit (`audit/backend.md`) {#backend-audit-extension}

Categories: `DB | NET | CPU | MEM | CONC | CODE | CONF | ARCH`
```markdown
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Maintenance window:** <Yes | No>                                   # adds
```

#### Security audit (`audit/security.md`) {#security-audit-extension}

Categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC | DEPS | PRIV`
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

#### Database audit (`audit/database.md`) {#database-audit-extension}

Categories: `MDL | IDX | QRY | WRT | CFG | SCH | PERF`
```markdown
- **Collection/Table:** <name(s) affected>                             # adds (before File)
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Requires migration:** <Yes | No>                                   # adds
```

#### Tests audit (`audit/tests.md`) {#tests-audit-extension}

Category: `TEST`
```markdown
- **Layer:** <unit | integration | e2e>                                # adds
- **Current confidence:** <0.0–1.0>                                    # adds
- **Closest test match:** <path or none>                               # adds
- **Effort:** <Hours | Days>                                           # adds
- **Suggestion:** <Fix snippet — example test that would cover the AC/SC>  # specializes Suggestion
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

**Tests audit** — additional fields:
```json
{
  "layer": "unit|integration|e2e",
  "currentConfidence": 0.0,
  "closestTestMatch": "path | none",
  "effort": "Hours|Days"
}
```

---

## Drift Analysis Findings {#drift-findings}

Used by `/ship:analyze` phase. Extends the base Finding Entry with drift-specific fields.

### Finding Entry Format

Fields: Severity (critical|high|medium|low, see severity.md#drift) · Category (see below) · File (path or —) · Description · Suggestion · Requirement ID (REQ-XX or —) · Criterion ID (AC-XX or —) · Scenario ID (SC-XX or —) · Layer (unit|integration|e2e or —, SCENARIO findings only) · Confidence % (integer 0-100).

Categories, each with its severity trigger and gate impact:

| Category | Meaning | Severity trigger | Gate |
|----------|---------|-------------------|------|
| IMPL | Implementation gap | Requirement with 0 code matches | FAIL (critical) |
| DRIFT | Low-confidence match | Requirement confidence < 0.5 | FAIL (high) |
| TEST | AC test coverage gap | Acceptance criterion with 0 test matches | WARN (medium) |
| SCENARIO | Scenario coverage gap | Scenario with 0 test matches in its tagged enabled layer | WARN (medium) |
| ORPHAN | Changed code/test with no matching requirement | — | WARN (medium) |
| DUP | Duplicate requirement/criterion | — | PASS (low) |
| AMBIG | Vague/unmeasurable term | No measurable threshold | WARN (medium) |
| SUBSPEC | Underspecified item (e.g. requirement without AC) | — | WARN (medium) |
| PRINCIPLE | Violation of a stated principle/convention | — | WARN (medium) |
| TERM | Terminology inconsistency spec↔code | — | PASS (low) |

Criterion/scenario confidence < 0.5 (any category) → low severity, PASS.

### Example Reports

`✓ Análise de Drift: PASS (0 gaps) — [ver relatório completo](link)`

```
### [CRITICAL] Requisito não implementado: REQ-05
- **Categoria:** IMPL
- **Descrição:** O requisito "REQ-05: Cache invalidation" não possui implementação identificada.
- **Sugestão:** Implemente o requisito REQ-05 no arquivo.
```

### Orphans

Rendered only when ORPHAN-category findings exist. Lists changed code/test artifacts that have no matching requirement. The rendered report starts this block with a `## Orphans` heading (analogous to `## Gaps`), followed by a table:

```markdown
| File/Identifier | Line | Best REQ match | Confidence % | Category |
|------------------|------|-----------------|---------------|----------|
| src/cache/evict.ts#evictExpired | 42 | REQ-05 (baixa confiança) | 22% | ORPHAN |
```

### JSON Schema

```json
{
  "severity": "critical | high | medium | low",
  "category": "IMPL | TEST | SCENARIO | DRIFT | ORPHAN | DUP | AMBIG | SUBSPEC | PRINCIPLE | TERM",
  "title": "string",
  "description": "string",
  "suggestion": "string",
  "requirementId": "REQ-XX | null",
  "criterionId": "AC-XX | null",
  "scenarioId": "SC-XX | null",
  "layer": "unit | integration | e2e | null",
  "filePath": "string | null",
  "line": "number | null",
  "confidence": "number 0-100 | null"
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
<!-- lazy-load algorithm: see the lazy-load-findings.md pattern (included above) -->

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
For the decision algorithm (how to determine PASS / WARN / FAIL), see the lazy-load-findings.md pattern (included above).

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

+ 3 low-severity findings — [see full report](https://linear.app/<workspace>/issue/<TEAM>-NNN)

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
```
