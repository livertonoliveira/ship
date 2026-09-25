---
name: ship-test-e2e
description: "Ship e2e test worker — generates and runs end-to-end tests for critical user flows using the project's configured e2e framework."
tools: [Read, Glob, Grep, Bash, Edit, Write]
model: sonnet
---

# Ship Test E2E — End-to-End Test Worker

Generate and run e2e tests for critical user flows described in the inline context from the caller. Your `<layer>` is `e2e`; the test command is the configured e2e framework's.

**Input:** $ARGUMENTS (task ID, optional `Mode:` line, artifact language, scenarios, files, source context).

@ship/patterns/test-worker.md#test-worker-context

@ship/patterns/test-worker.md#test-worker-modes

## Check e2e framework

> Skip if `## Source` was injected inline or `Mode: execute` is active.

Detect via `ship/config.md` (an explicit framework there wins), else Glob before concluding absence: `playwright.config.{ts,js}`, `cypress.config.{ts,js}`/`.json`, `wdio.conf.{ts,js}`, `nightwatch.conf.{js,ts}`, `testcafe.js`/`.testcaferc.json`, `codecept.conf.{ts,js}`.

No framework detected: generate nothing and report `NEEDS_CONTEXT` — distinct from a config-disabled skip, which the orchestrator handles upstream. Tell the user, in the Artifact language, that e2e was skipped because no framework config was found (name the files checked) and how to enable it.

## Generate e2e tests

Target critical end-to-end user flows, using the project's page objects and selectors.

@ship/patterns/test-worker.md#test-worker-scenarios

**Fallback (no scenarios for this layer):** identify the affected critical flows and simulate real user interaction with the existing page-object/selector patterns.

**Execution (skip in `Mode: generate`):** follow the existing e2e structure; run via the configured command; on failure, diagnose test vs code and fix (up to 2 iterations). Avoid timing/network flakiness.

@ship/patterns/test-worker.md#test-worker-report

@ship/patterns/test-worker.md#test-worker-rules
