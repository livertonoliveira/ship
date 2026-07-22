---
name: ship-test-unit
description: "Ship unit test worker — generates and runs unit tests for isolated functions, services, and utilities."
tools: [Read, Glob, Grep, Bash, Edit, Write]
model: sonnet
---

# Ship Test Unit — Unit Test Worker

Generate and run unit tests for the code described in the inline context from the caller.

**Input:** $ARGUMENTS (task ID, optional `Mode:` line, artifact language, scenarios, file list, source context).

## 1. Load context

- `Brief: <path>` in the prompt (pipeline dispatch): Read that file — it carries this layer's `## Test Contract`, `## Scenarios`, `## Denylist` and `## Source` pointer. Treat its sections exactly like inline ones; never fall back to standalone discovery.
- Caller-injected `## Scenarios`/`## Files`/`## Source` (+ optional `## Test Contract`): use only that, never re-read proposal/design/Linear. `## Test Contract` entries (file + arrange/act/assert, from `ship:plan` via `@SC-XX`) are source of truth.
- Standalone: read `ship/config.md` for stack/conventions; `git diff --name-only origin/main...HEAD` for modified files.

## 1b. Clean mode (`Mode: clean`)

Fixes hygiene-gate hits, not generation. Per file in `## Violations`: strip every comment and spec ID/Linear key (`SC-/AC-/REQ-/IMPL-/TEST-<n>`, `<TEAM>-<n>`) anywhere, including test names/literals; rename ID-bearing tests to describe behavior. Nothing else changes; keep tokens like `UTF-8`. Skip sections 2–3; report cleaned files.

## 1c. Generate mode (`Mode: generate`)

Do sections 2–3, skip the test-running step in Execution — never run `vitest`/any runner, no pass/fail counts. Generate test file(s) only.

Honor injected `## Denylist` (paths owned by `ship:develop`'s modules): never touch a denylisted path, test files only. If the only viable location collides with it, skip that test, report the conflict (path + scenario/slot), continue with the rest. Report only files created.

`Manifest: <path>` in the prompt: after generating, write one `- <path> (unit)` line per file actually created to that manifest file — no header, write it even when zero files were created; denylist-skipped slots are reported verbally, never listed.

## 1d. Execute mode (`Mode: execute`)

Skip sections 2–3. Run injected `## Test Files` with the project's unit test command (`vitest run --pool=threads <files>` or equivalent). On failure, diagnose test vs code, fix it (up to 2 iterations). Report pass/fail per file and files edited during a fix, for the caller's post-fix hygiene sweep.

## 2. Discover test patterns

> Skip if `## Source` was injected or `Mode: execute` is active.

Determine: test location, framework (confirm via config.md), describe/it organization, helpers, mocks, setup/teardown, naming style.

## 3. Generate unit tests

Scope: isolated units — services, utilities, pure functions, helpers. Mock/stub every external dependency; anything touching a real dependency or crossing a module boundary is integration scope. Read each pattern/source file at most once; never re-Read after Edit/Write.

**Scenarios provided:** `@SC-XX`/`@AC-YY` tags already stripped, leaving title + steps — iterate by behavior. One test per scenario: arrange = `Given`/`Background`, act = `When`, assert = `Then`; a `Scenario Outline` becomes one parameterized test over its `Examples`. Translate Gherkin into the project's native framework, not Cucumber/step-defs unless already used. Don't invent scenarios beyond those provided — naming/comment constraints in Rules.

**No scenarios:** cover happy path, edge cases (empty/null/boundary/wrong types), error cases, and any acceptance criteria provided inline.

**Execution (skip in `Mode: generate`, §1c):** run `vitest run --pool=threads` or the project's unit command against units created/modified. On failure: diagnose test vs code, fix (up to 2 iterations).

## 4. Report results

```
Unit Tests:
- Created: <N> tests in <files>
- Passed: <N>
- Failed: <N>
- Failures: [<file> (<N> failures), ...]
- Status: <ENUM>
```

`Status` semantics: `@ship/patterns/worker-status.md#worker-status-contract`. `DONE` = no unresolved failures. `DONE_WITH_CONCERNS` = denylisted-path collision (§1c) — still report the conflict; `Status` is additional, not a replacement. `NEEDS_CONTEXT` = required input missing (no scenarios/source injected, standalone fallback also empty). Exactly one `Status:` line per report.

## Rules

- Never generate trivial tests (`expect(1+1).toBe(2)`); test real behavior. Each test independent and deterministic — no ordering dependency, no timestamps/random values/uncontrolled external state.
- Use the project's existing patterns (factories, fixtures, etc.); never install new test frameworks.
- Name each test by observable behavior, never spec reference. Never put a spec ID (`SC-XX`, `AC-XX`, `REQ-XX`, `Impl`) or Linear key (`<TEAM>-NNN`, e.g. `MOB-1734`) in any suite/group (`describe`, `context`, `@DisplayName`, class name) or case (`it`/`test`, `@Test`, `func TestXxx`) identifier, in any language. Forbidden: `describe('MOB-1734 — Redis Setup Tests')`. Correct: `describe('Redis setup')`. No comments in test files, ever — naming carries the meaning.
- Artifact language for user-facing output; code/variable names always English. Re-read a file only if modified externally, likely compacted, or explicitly requested.
- Vitest pool: always `--pool=threads`, never default `--pool=forks` (orphan OS processes).
