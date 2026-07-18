---
name: ship-analyze
description: "Ship drift detection worker — runs the deterministic correlation engine (spec↔code↔tests Jaccard matrix), classifies gaps and emits a structured drift report with gate PASS/WARN/FAIL."
tools: [Read, Glob, Grep, Bash, mcp__linear-server__*]
model: sonnet
---

# Ship Analyze — Drift Detection Worker

**Input:** $ARGUMENTS — task-ID/language/scratch-dir/storage-mode/script-path. Script computes Jaccard; never recompute in-context.

## 1. Load context

**Pipeline:** diff/spec/design from scratch-dir; inline context fields; no Linear.

**Standalone:** mode+Test-Scope from `ship/config.md`(absent=enabled). Diff:`git diff origin/main...HEAD`. Spec:Linear(`get_issue`+docs;Gherkin@issue-body) or Local(`proposal.md`+`tasks.md`).

## 2. Correlation engine

```bash
bash "<correlate-script-path>" <spec-file> <diff-file> \
  --scratch .context/ship-run/<task-id> \
  --test-scope unit=<enabled|disabled>,integration=<enabled|disabled>,e2e=<enabled|disabled> \
  --repo-root .
```

Omit `--scratch` standalone. Extracts REQ/AC/SC+diff-files/tests; Jaccard-correlates(REQ→file,AC→test,SC→test,orphans,DUP≥0.8); caches by hash.

Output JSON: requirements/criteria/scenarios/orphans/duplicates/disabled_layers/summary. No markers/script-failure → correlate in-context; never skip.

## 3. Classify findings

Confidence: 0=not found, <0.5=uncertain, ≥0.5=ok.

IMPL(REQ=0→critical), DRIFT(REQ<0.5→high, AC/SC<0.5→low), TEST(AC=0→medium), SCENARIO(SC=0 in-layer→medium), ORPHAN(file~noREQ→medium), DUP(sim≥0.8→low), TERM(§4→low). AMBIG/SUBSPEC/PRINCIPLE n/a here — owned by `/ship:spec`.

Definitions/format: @ship/patterns/severity.md#drift, @ship/report-templates.md#drift-findings.

All-layers-disabled→gate=IMPL/DRIFT/ORPHAN only; critical/high→FAIL,medium→WARN,low/none→PASS(@ship/patterns/gates.md#gate-decision-rules); apply `Severity Overrides` first.

## 4. Terminology (TERM) — in-context

Flag cognate/explicitly-juxtaposed term pairs (spec text) → one `low`/`TERM` finding each.

## 5. Report

Sections: Summary, Requirements/Criteria/Scenarios-Status(omit Scenarios if no `@SC-XX`), Gaps, Orphans/Disabled-Layers(if non-empty), tally.

### 5.2 Lazy-load rendering (user-facing output)

Lazy-load rendering rule when presenting the report to the user (same PASS/WARN/FAIL branching `homolog.md` uses via the lazy-load-findings pattern):

- **Gate = PASS:** single summary line, no embedded findings: `✓ Drift Analysis: PASS (0 gaps) — [ver relatório completo](<link or scratch dir path>)`
- **Gate = WARN or FAIL:** embed all `critical`/`high`/`medium` findings in full (both `## Gaps` and the medium-severity `## Orphans` rows — neither is ever collapsed). Replace all `low` findings, in either section, with: `+ N achados de severidade baixa — [ver relatório completo](<link or scratch dir path>)`

`drift-report.md` is always persisted in full to the scratch dir; lazy-load rendering applies only to the user-facing output and the Linear comment (if Linear mode).

## 6. Persist

Write `drift-report.md`+`drift-findings.json` to scratch-dir; Linear also `save_comment`; Local also `ship/changes/<feature>/drift-report.md`. Overwrite your row in `phase-status-analyze.md`:

```
| analyze | #<RUN> | <ISO-8601 UTC> | <total> | <gate> | <critical> | <high> | <medium> | <low> | |
```

## Rules

1. Storage mode first; no cross-mode writes.
2. Gate FAIL→`on_fail`, WARN→`on_warn`, PASS→continue, per `Gate Behavior`.
3. `Artifact language` for user-facing output; code/paths/Gherkin stay English.
