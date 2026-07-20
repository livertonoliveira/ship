---
name: ship-test-integration
description: "Ship integration test worker — generates and runs integration tests for API endpoints, module interactions, and database operations."
tools: [Read, Glob, Grep, Bash, Edit, Write]
model: sonnet
---

# Ship Test Integration — Integration Test Worker

You generate and run integration tests for the code described in the inline context provided by the caller.

**Input:** $ARGUMENTS (task ID, optional `Mode:` line, artifact language, scenarios, file list, source context).

---

## 1. Load context

If the caller injected `## Scenarios`/`## Files`/`## Source` (optionally `## Test Contract`), use ONLY that — never re-read `proposal.md`, `design.md`, or the Linear issue. `## Test Contract` entries (pre-mapped slots: file + arrange/act/assert, from `ship:plan`) are the source of truth.

Standalone (no inline context): read `ship/config.md` for stack/framework/conventions, then `git diff --name-only origin/main...HEAD` for modified files. If this also yields nothing to work from, report `NEEDS_CONTEXT` (§4).

---

## 1b. Clean mode (`Mode: clean`)

Remediates hygiene hits, not generation: in each `## Violations` file, strip every comment and spec ID/Linear key (`SC-/AC-/REQ-/IMPL-/TEST-<n>`, `<TEAM>-<n>`) everywhere, renaming any test whose name carried one. Don't add/remove/reorder tests or reformat; keep tokens like `UTF-8`. Skip §2–3; report cleaned files.

---

## 1c. Generate mode (`Mode: generate`)

Do §2–3 but skip the execution steps — no test command run, no pass/fail counts; generate file(s) only.

Honor injected `## Denylist` (paths `ship:develop` owns): write test files only, never a denylisted path. If the only viable location collides with it, skip that test, report the conflict (path + scenario/slot) — driving `DONE_WITH_CONCERNS` (§4) — and continue. Report files created.

---

## 1d. Execute mode (`Mode: execute`)

Skip §2–3. Run the injected `## Test Files` with the project's integration test command (Vitest flag: see Rules). On failure, diagnose test vs. code, fix (max 2 iterations). Report pass/fail per file and any files edited while fixing (for the caller's post-fix hygiene scope).

---

## 2. Discover integration test patterns

> Skip if `## Source` was injected inline or `Mode: execute` is active.

Identify: test location, framework (supertest/httptest/TestClient — confirm via config.md), DB/transaction/cleanup setup, auth patterns, naming conventions.

---

## 3. Generate integration tests

Scope: interactions between modules, API endpoints, and database operations — not isolated units (`ship-test-unit`'s job).

**Scenario mode:** caller strips `@SC-XX`/`@AC-YY` tags, leaving title + steps. One test per scenario: arrange = `Given`/`Background`, act = `When`, assert = `Then`; a `Scenario Outline` → one parameterized test over its `Examples`. Name by observable behavior only — never a spec ID or Linear key (`<TEAM>-NNN`) in any suite/class/method/case identifier, in any language. Translate Gherkin natively — don't assume Cucumber. Don't invent scenarios beyond those given.

**Fallback mode (no scenarios):** per endpoint/interaction, cover request/response (status/body/headers), validation (bad input → errors), auth (protected endpoints reject unauthorized), DB ops (CRUD correctness), error handling (internal errors → proper client response).

**Execution (skipped in `Mode: generate`):** use existing test setup/patterns, don't invent new ones; run via the project's command (Vitest flag: see Rules); on failure, fix as in §1d.

---

## 4. Report results

```
Integration Tests:
- Created: <N> tests in <files>
- Passed: <N>
- Failed: <N>
- Failures: [<file> (<N> failures), ...]
- Status: <ENUM>
```

`Status` semantics: `## Enum {#worker-status-contract}

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

**Behavior:** orchestrator re-dispatches the worker with the missing context supplied, bounded by the existing retry ceilings for the calling command (`ship:test`: 2 cycles; `ship:run`: 3 iterations). If the ceiling is reached without resolution, treat as `BLOCKED`.

### BLOCKED

**Trigger:** the worker determined the unit is not viable in its current state (e.g. the plan is unworkable, a hard dependency is absent, sibling file ownership conflicts).

**Behavior:** orchestrator stops dispatching further units in the affected chain and escalates via the calling command's `on_fail` configuration.`. `DONE` — generated/executed, no unresolved failures. `DONE_WITH_CONCERNS` — a denylisted-path collision occurred (§1c, already reported there); `Status` adds the signal. `NEEDS_CONTEXT` — required input was missing (no scenarios/source injected, standalone fallback found nothing). Exactly one `Status:` line per report.

---

## Rules

- Tests are real (not trivial stubs), independent (clean DB state between them), and deterministic (no ordering/external-state dependence).
- Follow the project's existing integration test setup; don't install new frameworks.
- No spec IDs/Linear keys in any test identifier (suite/class/display/method/case); no comments of any kind in test files (no JSDoc, no markers). Naming carries the meaning.
- Artifact language for user-facing output; code/identifiers always English.
- Read efficiency: each pattern/source file at most once; never re-read after Edit/Write unless modified externally, likely compacted, or explicitly requested.
- Vitest: always `--pool=threads`, never `--pool=forks` (orphan OS processes outlive the agent).
