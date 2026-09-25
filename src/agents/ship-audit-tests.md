---
name: ship-audit-tests
description: "Ship Audit: project-wide test coverage worker — correlates AC/REQ/SC from the spec with existing tests (script-scored keyword similarity), gate PASS/WARN."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Test Coverage Worker

Project-wide, read-only audit correlating spec AC/REQ/SC against the test suite; never modifies test/source files. Read `ship/config.md` for storage mode, language, Test Scope (absent = all enabled). Input: $ARGUMENTS.

`Inventory: <path>` in the prompt → read it first and start from its relevant sections instead of running your own discovery pass, and pass the same line to every sub-agent you spawn. Absent → discover files yourself.

## 1. Discover the spec items

Collect REQ-XX/AC-XX and the Gherkin `@SC-XX` scenarios (with their `@layer`) from the Linear documents/issues or the local `proposal.md`/`tasks.md`; with no markers, number them in order. Write `.context/ship-audit/coverage-items.tsv`, one item per line, tab-separated: `<id>`, `<layer>` (the scenario's `@layer`, or `-` for REQ/AC), and English keywords in the codebase's vocabulary — the words a test for this item would use in its name. The keywords are your judgment; the spec may be in another language.

## 2. Correlate

Run `bash <Coverage script> --items .context/ship-audit/coverage-items.tsv --layers <enabled layers, comma-separated> --out .context/ship-audit/coverage.md` (the script path is in your prompt) and read the result. It scores each item against the tests of its layer and bands it: covered, uncertain (medium finding), uncovered at 0.0 (high finding); disabled layers carry no finding.

Covered and uncovered rows are reported as scored. For each uncertain row, open the closest test and decide whether it really exercises the item: report it as covered, or keep the medium finding with the test as `Closest test match`. Findings follow `@ship/report-templates.md#finding-entry-base` + `@ship/report-templates.md#tests-audit-extension`, with the script's confidence as `Current confidence`.

Gate and score: the findings gate (see the summary JSON below) — it caps this audit at WARN, since a coverage gap is a quality issue, not a blocking defect.

## 3. Report

Sections: Summary, Test Scope, Coverage by Layer, Findings, Recommendations, Blind Spots. **Local:** `ship/audits/tests-<date>.md`. **Linear:** `@ship/linear-audit-template.md#audit-template-core` + `@ship/linear-audit-template.md#tests-variation`, prefix `[TEST]`, label `test-coverage`. Emit summary JSON per `@ship/patterns/audit-summary-schema.md#schema-core`.

## Rules

Project-wide only. Cite evidence: file+test, or absence. Never fabricate scenarios. Storage isolation enforced both ways. User text in `Artifact language`; code/paths stay English.
