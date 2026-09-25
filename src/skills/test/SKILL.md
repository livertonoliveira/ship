---
name: ship:test
description: "Standalone test fan-out — only layers enabled in Test Scope are launched. In the pipeline, pipeline.sh next dispatches the workers directly."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
user-invocable: true
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Test — Standalone Fan-out

Read Test Scope, resolve scenarios by layer, fan out to named agents in parallel.

> **Pipeline note:** inside `/ship:run`, `pipeline.sh next` dispatches the `ship-test-*` workers directly with deterministic per-layer briefs — it never invokes this skill. This is the standalone, user-invoked entry.

You have no Edit/Write tools: tests are written and run only by the `ship-test-*` workers you dispatch via the Agent tool. Resolve layers, then dispatch.

**Input received:** $ARGUMENTS (task ID as the first token, then optional `Mode:`, artifact language, scenarios, modified files)

## 1. Load context

Parse `$ARGUMENTS`: `task-id` = first token (absent → derive from branch name or `standalone`). Parse `Mode:` — `generate`/`execute`/`full`, default `full`. Layers = `bash "@@ship/hooks/test-scope.sh" --config ship/config.md` (`run=`/`skip=`, deterministic — never compute in prose). Read `Artifact language` from `ship/config.md`.

**Scenarios:** injected inline → use as-is. Otherwise parse the task's Gherkin: Linear reads the issue body via MCP (unavailable → fall back local, warn); Local reads `proposal.md`'s `## Acceptance Criteria`. Group scenarios by `@layer` tag — never re-classify. If `plan.md` with a `## Test Contract` exists, pass each layer's slots to its worker (source of truth). Log layers enabled/disabled + mode.

## 2. Guard — all layers disabled

`run=` empty → tell the user, in the Artifact language, that the test phase was skipped because every layer is disabled in `Test Scope`, and stop. Applies to every mode.

## 3. Fan out to named agents (parallel)

For each layer in `run=`, dispatch via the Agent tool with `subagent_type: ship:ship-test-<layer>` (unit → `ship-test-unit`, integration → `ship-test-integration`, e2e → `ship-test-e2e`). Never dispatch a layer in `skip=` (log `Skipping [layer] tests (disabled in Test Scope)`; some skipped → tell the user, in the Artifact language, which layers were skipped and that `Test Scope` enables them).

**Context slicing — always pass inline, never rely on the agent re-reading:**
1. Filter scenarios: only `@unit`/`@integration`/`@e2e` tagged for the respective agent — never the full list to all.
2. Resolve the diff **once**, pass inline as `## Source`: `bash "@@ship/hooks/capture-diff.sh" .context/ship-run/<task-id>/diff.md --prefer .context/ship-run/<task-id>/diff.md`, then read that file.
3. Prompt: `Task ID` / `Artifact language` / `## Test Contract` (this layer's slots, omit if none) / `## Scenarios` (filtered) / `## Files` / `## Source`.
4. **De-identify before injecting** — pipe the `## Test Contract` and `## Scenarios` text through `bash "@@ship/hooks/deidentify.sh" --team <Linear team key>` (omit `--team` in local mode) and inject its output; why: `@@ship/patterns/deidentify-context.md`.
5. Agents receiving these sections inline MUST NOT fall back to standalone discovery.

**Mode: generate delta** — add `Mode: generate` after `Task ID:`; append `## Denylist` (paths the worker must never touch: `plan.md` module file sets, else the task's `## Files` create/modify paths); workers generate only, no test command, no pass/fail report.

**Mode: execute** — skip generation: read `generated-tests.md` if present (group by layer) or take the user-given files, dispatch the matching worker(s) with `## Test Files` to run exactly those.

**Mode: full (default)** — no `Mode:` line, no denylist: each worker runs its full generate+execute cycle.

## 4. Hygiene sweep after generate/full

```bash
bash "@@ship/hooks/hygiene-scan.sh" --all 2>&1
```
Hits → dispatch a cleanup worker per flagged file (`Mode: clean`, matching layer type), pass exact `file:line` hits, re-run. Hits remain after 2nd cycle → surface `warn` — never report clean with known hits.

## 5. Self-check before returning

1. Every `run=` layer — issued a `ship-test-*` Agent call? If not, dispatch the missing workers.
2. `generate`/`full`: hygiene sweep actually ran and hits were remediated?
3. Report per layer: tests created (and passed/failed for `full`/`execute`).
