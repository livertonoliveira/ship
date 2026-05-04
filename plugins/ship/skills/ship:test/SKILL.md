---
name: ship:test
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
1. `ship/config.md` — Test framework, commands, conventions
2. `ship/changes/<feature>/proposal.md` — Acceptance criteria (guide the tests)
3. `ship/changes/<feature>/design.md` — Files created/modified
4. `ship/changes/<feature>/tasks.md` — Testing section to update

### 2. Identify existing test patterns

Before generating any test, explore the project to understand:
- **Where tests are located**: `__tests__/`, `*.spec.ts`, `*.test.ts`, `tests/`, `test_*.py`, `*_test.go`, etc.
- **Framework used**: Vitest, Jest, Mocha, pytest, go test, RSpec, JUnit, etc. (confirm with config.md)
- **Test patterns**: how describes/its are organized, which helpers exist, how mocks are done
- **Setup/teardown**: factories, fixtures, test databases, cleanup patterns
- **Naming**: how tests are named ("should X when Y", "test_X_returns_Y", etc.)

### 3. Generate tests (3 agents in parallel)

Launch **3 agents in parallel** using the Agent tool:

**Agent A — Unit Tests:**

Responsibility: test isolated units (services, utilities, pure functions, helpers).

1. Identify all services, utilities, and functions created/modified in the feature
2. For each one, generate tests covering:
   - **Happy path**: expected behavior with valid inputs
   - **Edge cases**: empty inputs, nulls, boundary values, incorrect types
   - **Error cases**: what happens when something fails (exceptions, rejections)
   - **Acceptance criteria**: tests that directly validate the criteria from proposal.md
3. Use mocks/stubs to isolate external dependencies (DB, APIs, etc.)
4. Follow existing test patterns in the project — do not invent new patterns
5. Run the tests and verify they pass
6. If any fail: analyze whether it is a bug in the test or in the code. Fix (up to 2 iterations).

**Agent B — Integration Tests:**

Responsibility: test interactions between modules, API endpoints, database operations.

1. Identify the endpoints, repositories, and module interactions of the feature
2. For each endpoint/interaction, generate tests covering:
   - **Request/Response**: correct status codes, correct body, headers
   - **Validation**: invalid inputs return appropriate errors
   - **Authentication/Authorization**: protected endpoints reject unauthorized access (if applicable)
   - **Database operations**: data is created/read/updated/deleted correctly
   - **Error handling**: internal errors return appropriate responses to the client
3. Use the existing integration test setup in the project (test database, supertest, httptest, etc.)
4. Run the tests and verify they pass
5. If any fail: fix (up to 2 iterations)

**Agent C — E2E Tests (if applicable):**

Responsibility: test critical end-to-end user flows.

1. Check if the project has an e2e framework configured (Playwright, Cypress, etc.) via config.md
2. If there is NO e2e framework: **do not generate e2e tests**. Report that e2e is not applicable.
3. If there IS an e2e framework:
   - Identify the critical user flows affected by the feature
   - Generate tests that simulate the user interacting with the application
   - Use page objects/selectors consistent with those existing in the project
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

4. **Write `test-failures.md` to the shared scratch dir** (always — even if all tests passed):

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

---

## Rules

- **Never generate trivial tests**: `expect(1+1).toBe(2)` has no value. Test real behavior.
- **Tests must be independent**: each test runs in isolation, without depending on another having run first
- **Tests must be deterministic**: no dependency on timestamps, random values, or uncontrolled external state
- **Use the project's patterns**: if the project uses factories, use factories. If it uses fixtures, use fixtures.
- **Do not install test frameworks**: use what is already configured in the project
- **Acceptance criteria guide the tests**: each criterion from proposal.md must have at least one corresponding test
- **Language**: See @ship/patterns/language.md.
- **ALWAYS launch 3 agents in parallel**: even if one of them concludes there are no tests to generate for its type, it must report this
- **ALWAYS use `--pool=threads`** when invoking vitest directly (e.g. `vitest run --pool=threads`). Never use the default `--pool=forks` — it spawns orphan OS processes that survive after the agent exits, consuming CPU and RAM indefinitely.
