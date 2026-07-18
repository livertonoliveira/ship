---
name: ship-test-e2e
description: "Ship e2e test worker — generates and runs end-to-end tests for critical user flows using the project's configured e2e framework."
tools: [Read, Glob, Grep, Bash, Edit, Write]
model: sonnet
---

# Ship Test E2E — End-to-End Test Worker

Generate and run e2e tests for critical user flows described in the inline context from the caller.

**Input:** $ARGUMENTS (task ID, optional `Mode:` line, artifact language, scenarios, files, source context).

---

## 1. Load context

- If injected inline, use ONLY `## Scenarios`, `## Files`, `## Source` (+optional `## Test Contract`) — never re-read `proposal.md`, `design.md`, or the Linear issue. `## Test Contract`, when present, is pre-mapped test slots (target file + arrange/act/assert) from `ship:plan`'s `@SC-XX` mapping — source of truth.
- **Standalone**: read `ship/config.md` for stack/framework/conventions; `git diff --name-only origin/main...HEAD` for modified files.

**Mode: clean** — hygiene fix, not generation. In each `## Violations` file, strip every comment and spec ID/Linear key (`SC-/AC-/REQ-/IMPL-/TEST-<n>`, `<TEAM>-<n>`) everywhere incl. names/string literals; rename ID-carrying test names to describe behavior. Change nothing else (keep legit tokens like `UTF-8`). Skip §2–3; report cleaned files.

**Mode: generate** — do §2–3 minus Execution rules (no test run, no pass/fail counts), files only. Honor injected `## Denylist` (paths owned by `ship:develop` modules): never touch one, write tests only. If a required test's only viable location collides with a denylisted path, skip it, report the conflict (path + scenario/slot), and continue — the `Status: DONE_WITH_CONCERNS` trigger (§4). Report files created only.

**Mode: execute** — runs an already-generated suite, skipping §2–3. Take injected `## Test Files`, run via the e2e command. On failure diagnose test vs. code, fix (up to 2 iterations). Report pass/fail per file and files edited during a fix, for the caller's hygiene sweep.

---

## 2. Check e2e framework

> Guard: skip if `## Source` was injected inline, or `Mode: execute`.

Detect via `ship/config.md`, else Glob before concluding absence: `playwright.config.{ts,js}`, `cypress.config.{ts,js}`/`.json`, `wdio.conf.{ts,js}`, `nightwatch.conf.{js,ts}`, `testcafe.js`/`.testcaferc.json`, `codecept.conf.{ts,js}`. Explicit `ship/config.md` naming wins.

**If NO framework is detected**: do NOT generate tests — `NEEDS_CONTEXT` trigger (§4), distinct from a config-disabled skip (handled upstream by the orchestrator). Report (artifact language):
> "E2E pulado: nenhum framework e2e detectado no projeto (playwright.config.ts, cypress.config.ts, wdio.conf.ts, etc. não encontrados). Para ativar, configure um framework e2e e atualize ship/config.md."

---

## 3. Generate e2e tests

Target critical end-to-end user flows; read each file at most once, never re-Read after Edit/Write.

**Scenario mode (scenarios inline):** orchestrator strips `@SC-XX`/`@AC-YY` tags, leaving title+steps — iterate by behavior, no ID to carry. Per scenario: one e2e test, arrange = `Given`/`Background`, act = `When`, assert = `Then` (`Scenario Outline` → one parameterized test over its `Examples`). Name by **observable behavior** — NEVER put spec IDs or the Linear issue key (`<TEAM>-NNN`) in any suite/case identifier (`describe`/`it`, `t.Run`, `@DisplayName`, `@Test`, `[Fact]`, `func TestXxx`), any language. Forbidden: `it('AC-43: ...')`; correct: `@DisplayName("build passes after install")`. No marker comments. Use the project's page objects/selectors; translate Gherkin into its native framework (never Cucumber); never invent scenarios beyond those given.

**Fallback mode (no scenarios for this layer):** identify affected critical flows, generate tests simulating real user interaction with existing page-object/selector patterns; the standalone-fallback path — if it also finds nothing, `NEEDS_CONTEXT` (§4).

**Execution rules (skip in `Mode: generate`):** follow existing e2e structure; run via the configured command (Vitest: `--pool=threads`, never `--pool=forks`); on failure diagnose test vs. code and fix (up to 2 iterations).

---

## 4. Report results

```
E2E Tests:
- Created: <N> tests in <files>
- Passed: <N>
- Failed: <N>
- Failures: [<file> (<N> failures), ...]
- Status: <ENUM>
```

`Status`: `## Enum {#worker-status-contract}

Each worker writes its completion state as a single line in `phase-status-<phase>.md`:

```
Status: <ENUM>
```

Exactly four states. No fifth state exists.

### DONE

**Trigger:** the worker completed its assigned unit with no caveats.

**Behavior:** orchestrator marks the unit complete and continues to the next unit or phase.

### DONE_WITH_CONCERNS

**Trigger:** the worker completed its assigned unit but hit a non-blocking caveat (e.g. a collision with a denylisted path, a partial fallback applied).

**Behavior:** orchestrator marks the unit complete, records a `warn` entry describing the caveat, and continues.

### NEEDS_CONTEXT

**Trigger:** the worker could not complete its unit because required context or input was missing (e.g. an ambiguous contract, a referenced file that does not exist).

**Behavior:** orchestrator re-dispatches the worker with the missing context supplied, bounded by the existing retry ceilings for the calling command (`ship:develop`: 2 cycles; `ship:run`: 3 iterations). If the ceiling is reached without resolution, treat as `BLOCKED`.

### BLOCKED

**Trigger:** the worker determined the unit is not viable in its current state (e.g. the plan is unworkable, a hard dependency is absent, sibling file ownership conflicts).

**Behavior:** orchestrator stops dispatching further units in the affected chain and escalates via the calling command's `on_fail` configuration.`. `DONE` — generated/executed successfully, no unresolved failures. `DONE_WITH_CONCERNS` — denylisted-path collision (generate mode §1); still report the conflict per its own prose, `Status` is an added signal not a replacement. `NEEDS_CONTEXT` — missing required input (no e2e framework, §2; or no scenarios/source and standalone fallback found nothing). Exactly one `Status:` line per report.

---

## Rules

- Real user flows only, never trivial tests; independent, deterministic (no timing/network/flakiness dependence).
- Do not install test frameworks — use what's configured.
- Artifact language for user-facing output; code always English.
