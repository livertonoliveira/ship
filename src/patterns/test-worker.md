# Test Worker Contract

Shared contract for the `ship-test-{unit,integration,e2e}` workers. Each worker includes these sections and adds only its layer's discovery, scope and fallback coverage. `<layer>` below is the including worker's layer (`unit`, `integration` or `e2e`).

## Load context {#test-worker-context}

- `Brief: <path>` in the prompt (pipeline dispatch): Read that file — it carries this layer's `## Test Contract`, `## Scenarios`, `## Denylist` and `## Source` pointer. Treat its sections exactly like inline ones; never fall back to standalone discovery.
- Caller-injected `## Scenarios`/`## Files`/`## Source` (+ optional `## Test Contract`): use only that, never re-read `proposal.md`, `design.md` or the Linear issue. `## Test Contract` entries (target file + arrange/act/assert, from `ship:plan`'s `@SC-XX` mapping) are the source of truth.
- Standalone: read `ship/config.md` for stack/framework/conventions, then `git diff --name-only origin/main...HEAD` for modified files. If that also yields nothing to work from, report `NEEDS_CONTEXT`.

## Modes {#test-worker-modes}

**`Mode: clean`** — fixes hygiene-gate hits, not generation. In each `## Violations` file, strip every comment and spec ID/Linear key (`SC-/AC-/REQ-/IMPL-/TEST-<n>`, `<TEAM>-<n>`) everywhere, including test names and string literals; rename ID-bearing tests to describe behavior. Change nothing else — don't add, remove, reorder or reformat tests; keep legitimate tokens like `UTF-8`. Skip discovery and generation; report cleaned files.

**`Mode: generate`** — do discovery and generation, skip every test-running step: no test command, no pass/fail counts, files only.
- Honor injected `## Denylist` (paths owned by `ship:develop`'s modules): write test files only, never a denylisted path. If a test's only viable location collides with one, skip that test, report the conflict (path + scenario/slot) and continue — this is the `DONE_WITH_CONCERNS` trigger. Report files created or extended.
- `Manifest: <path>` in the prompt: after generating, write one `- <path> (<layer>)` line per file actually created **or extended** (an existing suite you added cases to counts too — an unlisted-but-changed file makes the gate re-run nothing, or everything) to that manifest file. No header; write it even when zero files were touched. Denylist-skipped slots are reported verbally, never listed.

**`Mode: execute`** — skip discovery and generation. Run the injected `## Test Files` with the project's `<layer>` test command. On failure, diagnose test vs. code and fix (up to 2 iterations). Report pass/fail per file and every file edited during a fix, for the caller's post-fix hygiene sweep.

## Scenarios {#test-worker-scenarios}

The caller strips `@SC-XX`/`@AC-YY` tags, leaving title + steps — iterate by behavior. One test per scenario: arrange = `Given`/`Background`, act = `When`, assert = `Then`; a `Scenario Outline` becomes one parameterized test over its `Examples`. Translate Gherkin into the project's native framework, not Cucumber/step definitions unless the project already uses them. Never invent scenarios beyond those given.

Name every test by observable behavior. No spec ID (`SC-XX`, `AC-XX`, `REQ-XX`, `Impl`) or Linear key (`<TEAM>-NNN`) in any suite/group (`describe`, `context`, `@DisplayName`, class name) or case (`it`/`test`, `@Test`, `[Fact]`, `t.Run`, `func TestXxx`) identifier, in any language — `describe('ABC-123 — Redis setup')` becomes `describe('Redis setup')`. No comments in test files; naming carries the meaning.

## Report {#test-worker-report}

```
<Layer> Tests:
- Created: <N> tests in <files>
- Passed: <N>
- Failed: <N>
- Failures: [<file> (<N> failures), ...]
- Status: <ENUM>
```

`Status` semantics: `@ship/patterns/worker-status.md#worker-status-contract`. `DONE` — generated/executed, no unresolved failures. `DONE_WITH_CONCERNS` — a denylisted-path collision occurred (already reported in generate mode); `Status` adds the signal, it does not replace the report. `NEEDS_CONTEXT` — required input missing (no scenarios/source injected and the standalone fallback found nothing, or a layer-specific precondition below). Exactly one `Status:` line per report.

## Rules {#test-worker-rules}

- Tests are real (never trivial like `expect(1+1).toBe(2)`), independent and deterministic — no ordering dependency, timestamps, random values or uncontrolled external state.
- Use the project's existing test setup and patterns (factories, fixtures, helpers); never install a new test framework.
- Read each pattern/source file at most once; re-read only if it was modified externally, the context was likely compacted, or the caller asks.
- Artifact language for user-facing output; code and identifiers always English.
- Vitest: always `--pool=threads`, never the default `--pool=forks` (orphan OS processes outlive the agent).
