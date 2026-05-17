---
name: test
description: "Ship Phase 3: generates and runs tests (unit, integration, e2e) with 3 parallel agents."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
user-invocable: true
---

# Ship Test — Test Generation and Execution

You are the Ship testing agent. Your mission is to generate comprehensive tests for the code implemented in the feature, covering unit tests, integration tests, and e2e tests, using parallel agents to maximize efficiency.

**Input received:** $ARGUMENTS

---

## Execution mode

Check if you are running inside the `/ship:run` pipeline:
- **Pipeline mode**: Read the artifacts from `ship/changes/<feature>/`.
- **Standalone mode**: Use `$ARGUMENTS` to identify the feature in `ship/changes/`. If not found, use `git diff --name-only` to identify files to test.

---

## Process

### 1. Load context

Read:
1. `ship/config.md` — Test framework, commands, conventions, and **`Test Scope`** section
2. `ship/changes/<feature>/proposal.md` — Acceptance criteria (guide the tests)
3. `ship/changes/<feature>/design.md` — Files created/modified
4. `ship/changes/<feature>/tasks.md` — Testing section to update, **and the `#### Scenarios` Gherkin block per task** (Linear mode: the task issue body carries the full `## Scenarios` Gherkin — already in the orchestrator-injected context)

**Resolve active test layers from `Test Scope`:**
After reading `ship/config.md`, extract the `## Test Scope` section. For each layer (`unit`, `integration`, `e2e`), check if it is `enabled` or `disabled`. If the section is absent, treat all three layers as `enabled` (backward-compatible default).

Log to the user which layers are active before launching agents:
```
Test layers: unit=enabled, integration=disabled, e2e=disabled
```

### 2. Identify existing test patterns

Before generating any test, explore the project to understand:
- **Where tests are located**: `__tests__/`, `*.spec.ts`, `*.test.ts`, `tests/`, `test_*.py`, `*_test.go`, etc.
- **Framework used**: Vitest, Jest, Mocha, pytest, go test, RSpec, JUnit, etc. (confirm with config.md)
- **Test patterns**: how describes/its are organized, which helpers exist, how mocks are done
- **Setup/teardown**: factories, fixtures, test databases, cleanup patterns
- **Naming**: how tests are named ("should X when Y", "test_X_returns_Y", etc.)

### 2.5. Resolve scenarios by layer

Before launching agents, parse the task's `## Scenarios` Gherkin block (from the issue body in Linear mode, or the `#### Scenarios` block in `tasks.md` in local mode). Each `Scenario` / `Scenario Outline` is tagged `@SC-XX`, `@AC-YY`, and exactly one layer tag (`@unit` | `@integration` | `@e2e`).

- Group scenarios strictly by their declared `@layer` tag. **Do NOT re-derive happy/edge/error cases or re-classify by guessing the layer** — the scenario set is authoritative and the layer is already declared. This is the work the spec phase already did; it is now input, not work.
- Pass each layer's `@SC-XX` subset (full Given/When/Then + any `Examples` table) inline in the respective agent's prompt. Do NOT instruct agents to re-read `proposal.md`, `design.md`, or the issue.

**Fallback (backward compatibility):** if a layer is enabled but the task has **zero** `@SC-XX` scenarios tagged for it (e.g., spec authored at `Scenario Depth: none`, or a legacy scenario-free spec), fall back to the previous behavior **for that layer only**: extract the relevant acceptance criteria from `proposal.md` and let the agent derive happy/edge/error tests. If the spec has no scenarios at all, the entire phase behaves exactly as before this feature.

### 3. Generate tests (up to 3 agents in parallel)

> **Layer guard**: Before launching, check the resolved `Test Scope` from step 1.
> - If a layer is `disabled`, **do not launch that agent** — log `Skipping [unit|integration|e2e] tests (disabled in Test Scope)` and continue.
> - Launch only agents for `enabled` layers.
> - **If all layers are disabled** → output the following message (in the artifact language from `ship/config.md → Conventions`):
>   > "Fase de testes pulada — todos os layers estão desabilitados em `Test Scope` (ship/config.md). Habilite ao menos um layer para gerar testes."
>   Then stop.
> - **If one or more layers are disabled but not all** → after individual skip logs, output a consolidated message (in artifact language):
>   > "Layers pulados por configuração: [&lt;list of disabled layers&gt;]. Para habilitá-los, edite `Test Scope` em `ship/config.md`."
> - **ALWAYS launch 3 agents** only when all 3 layers are enabled.

Launch agents in parallel using the Agent tool (only for enabled layers):

**Agent A — Unit Tests:**

> **Skip this agent if `unit` is `disabled` in `## Test Scope` of `ship/config.md`.**
> **Inline context**: the unit-layer ACs and relevant file list are provided inline in your prompt by the orchestrator. Do not re-read `proposal.md` or `design.md`.

Responsibility: test isolated units (services, utilities, pure functions, helpers).

0. **Read efficiency**: each test pattern / source file at most ONCE per agent. Do not re-Read after Edit/Write — those tools validate. If a snippet was already quoted in this prompt, reuse it instead of reopening.
1. Identify all services, utilities, and functions created/modified in the feature
2. **Scenario mode (normal case — `@SC-XX` scenarios provided inline):** for each provided `@SC-XX`, generate **exactly one** test where arrange = the scenario's `Given`/`Background`, act = the `When`, assert = the `Then`. A `Scenario Outline` → one parameterized/table-driven test iterating its `Examples` rows. Tag every test with a `// TEST-SC-XX` marker comment and name it after the scenario (referencing SC-XX). Translate Gherkin steps into the project's **native** test framework — do NOT assume Cucumber/step-defs unless the project already uses them. Do not invent scenarios beyond those provided; if a provided scenario obviously implies a sub-case, still tag it with the same parent `// TEST-SC-XX`.
   **Fallback mode (no scenarios provided for this layer):** generate tests covering — **Happy path** (valid inputs), **Edge cases** (empty/null/boundary/wrong types), **Error cases** (exceptions/rejections), and **Acceptance criteria** (directly validate the ACs provided inline).
3. Use mocks/stubs to isolate external dependencies (DB, APIs, etc.)
4. Follow existing test patterns in the project — do not invent new patterns
5. Run the tests and verify they pass
6. If any fail: analyze whether it is a bug in the test or in the code. Fix (up to 2 iterations).

**Agent B — Integration Tests:**

> **Skip this agent if `integration` is `disabled` in `## Test Scope` of `ship/config.md`.**
> **Inline context**: the integration-layer ACs and relevant file list are provided inline in your prompt by the orchestrator. Do not re-read `proposal.md` or `design.md`.

Responsibility: test interactions between modules, API endpoints, database operations.

0. **Read efficiency**: each test pattern / source file at most ONCE per agent. Do not re-Read after Edit/Write — those tools validate. If a snippet was already quoted in this prompt, reuse it instead of reopening.
1. Identify the endpoints, repositories, and module interactions of the feature
2. **Scenario mode (normal case — `@SC-XX` scenarios provided inline):** for each provided `@SC-XX`, generate **exactly one** test (arrange=`Given`, act=`When`, assert=`Then`; `Scenario Outline` → one parameterized test over its `Examples`). Tag each with `// TEST-SC-XX` and name it after the scenario. Translate Gherkin into the project's native integration setup — do NOT assume Cucumber.
   **Fallback mode (no scenarios provided for this layer):** for each endpoint/interaction, generate tests covering — **Request/Response** (status codes, body, headers), **Validation** (invalid inputs → appropriate errors), **Authentication/Authorization** (protected endpoints reject unauthorized access, if applicable), **Database operations** (CRUD correctness), **Error handling** (internal errors → appropriate client responses).
3. Use the existing integration test setup in the project (test database, supertest, httptest, etc.)
4. Run the tests and verify they pass
5. If any fail: fix (up to 2 iterations)

**Agent C — E2E Tests (if applicable):**

> **Skip this agent if `e2e` is `disabled` in `## Test Scope` of `ship/config.md`.**
> **Inline context**: the e2e-layer ACs and relevant file list are provided inline in your prompt by the orchestrator. Do not re-read `proposal.md` or `design.md`.

Responsibility: test critical end-to-end user flows.

0. **Read efficiency**: each test pattern / source file at most ONCE per agent. Do not re-Read after Edit/Write — those tools validate. If a snippet was already quoted in this prompt, reuse it instead of reopening.
1. Check if the project has an e2e framework configured (Playwright, Cypress, etc.) via config.md
2. If there is NO e2e framework: **do not generate e2e tests**. Report (in artifact language) that e2e was skipped due to no framework detected — distinguish this clearly from a config-disabled skip. Example: "E2E pulado: nenhum framework e2e detectado no projeto (Playwright, Cypress, etc.). Para ativar, configure um framework e2e (ex: Playwright ou Cypress)."
3. If there IS an e2e framework:
   - **Scenario mode (normal case — `@SC-XX` scenarios provided inline):** generate **exactly one** e2e test per provided `@SC-XX` (arrange=`Given`, act=`When`, assert=`Then`; `Scenario Outline` → one parameterized test over its `Examples`). Tag each with `// TEST-SC-XX` and name it after the scenario. Use page objects/selectors consistent with the project; translate Gherkin into the project's native e2e framework — do NOT assume Cucumber.
   - **Fallback mode (no scenarios provided):** identify the critical user flows affected by the feature and generate tests that simulate the user interacting with the application, using consistent page objects/selectors.
   - Run the tests and verify they pass
   - If any fail: fix (up to 2 iterations)

### 4. Consolidate results

After all 3 agents complete:

1. Collect the results from each agent:
   - Number of tests created by type
   - Number passing/failing
   - Coverage (if available)

2. Update `ship/changes/<feature>/tasks.md`:
   - Mark test items as completed or failed according to results
   - If all passed: mark `2.4 All tests passing` as completed

3. If any test failed after fix attempts: clearly report which ones failed and why.

### 5. Write test-failures.md

Always write this file after all agents complete — even if all tests passed:

- Collect all files that have failing tests from the output of the test runners (unit, integration, e2e).
- Write to `.context/ship-run/<task-id>/test-failures.md`:
  - **If there are failures**, list them in this format:
    ```markdown
    # Test Failures

    - src/auth/auth.service.ts (3 failures)
    - src/users/users.repo.ts (1 failure)
    ```
  - **If zero failures**, write only the header (absence of list items signals all tests passed):
    ```markdown
    # Test Failures
    ```
- This file signals to downstream phases (e.g., review) which modules need extra attention.
- `<task-id>` is the Linear issue ID (e.g., `MOB-1149`) or feature slug in local mode.
- **Standalone mode**: if running outside `/ship:run` (no scratch dir initialized), skip this step entirely.

### 6. Read efficiency

Avoid wasted Reads — they are the dominant token sink in this phase.

- Re-Read a file ONLY when one of the following is true:
  1. The file was modified by an external process (build, another subagent, user command) since the last Read.
  2. The content was likely compacted out of the current context window (long session, many turns since the original Read).
  3. The user explicitly asked to re-read it.
- After Edit/Write, do NOT re-Read to "confirm". These tools already validate and return errors on failure.
- When dispatching parallel subagents (step 3), pass the relevant file excerpts directly in the agent prompt instead of asking the agent to reopen them. The orchestrator's prompt is already cached; a fresh Read inside an empty subagent window is new input.

---

## Rules

- **Never generate trivial tests**: `expect(1+1).toBe(2)` has no value. Test real behavior.
- **Tests must be independent**: each test runs in isolation, without depending on another having run first
- **Tests must be deterministic**: no dependency on timestamps, random values, or uncontrolled external state
- **Use the project's patterns**: if the project uses factories, use factories. If it uses fixtures, use fixtures.
- **Do not install test frameworks**: use what is already configured in the project
- **Scenarios drive the tests**: when `@SC-XX` scenarios are provided, each must have exactly one corresponding `// TEST-SC-XX`-tagged test (a `Scenario Outline` counts as one parameterized test). ACs are covered transitively through their scenarios. Only in the fallback case (no scenarios for a layer) does the rule become "each acceptance criterion from proposal.md must have at least one corresponding test".
- **Language**: When running inside the pipeline, use the `artifact_language` injected by the orchestrator in this prompt. For standalone use, read `Artifact language` from `ship/config.md → Conventions` per @ship/patterns/language.md.
- **Respect `Test Scope`**: only launch agents for layers that are `enabled` in `ship/config.md → ## Test Scope`. If the section is absent, default all layers to `enabled`.
- **ALWAYS launch 3 agents in parallel when all layers are enabled**: even if one of them concludes there are no tests to generate for its type, it must report this
- **ALWAYS use `--pool=threads`** when invoking vitest directly (e.g. `vitest run --pool=threads`). Never use the default `--pool=forks` — it spawns orphan OS processes that survive after the agent exits, consuming CPU and RAM indefinitely.
