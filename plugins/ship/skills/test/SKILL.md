---
name: ship:test
description: "Ship Phase 3: fan-out orchestrator — only layers enabled in Test Scope are launched."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
user-invocable: true
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Test — Fan-out Orchestrator

Read Test Scope, resolve scenarios by layer, fan out to named agents in parallel.

> **CRITICAL — act, don't narrate.** No Edit/Write tools; the ONLY way tests get written/run is dispatching `ship-test-*` workers via the **Agent tool**. A plan with zero Agent calls is a **hard failure**. Resolve layers, then dispatch immediately.

**Input received:** $ARGUMENTS (task ID as the first token, then optional `Mode:`, artifact language, scenarios, modified files)

## 1. Load context

Parse `$ARGUMENTS`: `task-id` = first token (standalone → derive from branch name or `standalone`). Parse `Mode:` — `generate`/`execute`/`full`, default `full`. Layers = `bash "${CLAUDE_SKILL_DIR}/hooks/test-scope.sh" --config ship/config.md` (`run=`/`skip=`, deterministic — never compute in prose). Read `Artifact language`; read `stack.md` (fallback `ship/config.md`).

**Read the plan:** `plan.md`'s `## Test Contract` — each `@SC-XX -> <layer> -> <test file>` entry (`arrange/act/assert`) is the concrete slot `ship:plan` mapped, the same interpretation `ship:develop` built from. Pass each layer's slots to its worker (step 3) so code and tests derive from one source. Absent → fall back to raw scenarios.

**If `## Scenarios` wasn't injected inline** — parse the task's Gherkin: Linear reads the issue body via MCP (unavailable → fall back local, warn); Local (or MCP unavailable) reads `proposal.md`'s `## Acceptance Criteria`. Group scenarios by `@layer` tag — never re-classify. Log layers enabled/disabled + mode.

## 2. Guard — all layers disabled

`run=` empty → output "Fase de testes pulada — todos os layers estão desabilitados em `Test Scope`..." and stop. Applies to every mode.

## 3. Mode: generate

Generation-only: writes test files, never runs a test command, never writes `test-failures.md`.

### 3.1 Resolve the denylist

`plan.md` exists → collect every file path across all modules' file sets (`ship:develop`'s owned files), injected as `## Denylist` below. Absent, `## Files` populated → its `create`/`modify` paths. Neither → empty denylist.

### 3.2 Fan out to named agents (parallel) — MANDATORY ACTION

For each layer in `run=`, dispatch via the Agent tool with `subagent_type: ship:ship-test-<layer>` (unit → `ship-test-unit`, integration → `ship-test-integration`, e2e → `ship-test-e2e`). Never dispatch a layer in `skip=` (log `Skipping [layer] tests (disabled in Test Scope)`). These mechanics are reused by `full`.

**Context slicing — always pass inline, never rely on the agent re-reading:**
1. Filter scenarios: only `@unit`/`@integration`/`@e2e` tagged for the respective agent — never the full list to all.
2. Resolve the diff **once**, pass inline as `## Source`. Never `git diff origin/main...HEAD` (three-dot, committed-only, empty mid-pipeline). Pipeline: read the authoritative `.context/ship-run/<task-id>/diff.md` (don't recompute). Standalone: `BASE=$(git merge-base origin/main HEAD); git add -A -N; git diff "$BASE"` (captures untracked).
3. Prompt: `Task ID` / `Artifact language` / `## Test Contract` (this layer's slots, omit if none) / `## Scenarios` (filtered) / `## Files` / `## Source`. Test Contract present → worker treats it as source of truth, Scenarios as behavioral reference.
4. **De-identify before injecting** — strip spec-ID tags, keep behavioral steps. `${CLAUDE_SKILL_DIR}/patterns/deidentify-context.md`.
5. Agents receiving these sections inline MUST NOT fall back to standalone discovery.

Some (not all) layers disabled → log: "Layers pulados por configuração: [...]. Para habilitá-los, edite `Test Scope`." **Generate delta:** add `Mode: generate` after `Task ID:`; append `## Denylist` (paths this worker must never touch) after `## Source`; generate only, no test command, no pass/fail report.

### 3.3 Hygiene gate — final sweep (MANDATORY)

Gate on the marker: `test -f .context/ship-run/.hygiene-hit`. Absent → skip `--all`, log "Ship hygiene — sweep skipped (clean phase)." (English literal), straight to 3.4.

Present → run as before:

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/hygiene-scan.sh" --all 2>&1
```
Hits → dispatch a cleanup worker per flagged file (`Mode: clean`, matching type), pass exact `file:line` hits, re-run. Hits remain after 2nd cycle → record, surface `warn` — never PASS with known hits. Sweep done (clean or `warn`) → `rm -f .context/ship-run/.hygiene-hit`, then 3.4.

### 3.4 Manifest + phase status

Write `.context/ship-run/<task-id>/generated-tests.md` — one line per actually-created file as `- <path> (<layer>)`, the exact form `test-exec.sh` parses (prose or any other shape silently fails to run); grouped by layer, header-only if none; never write `test-failures.md` in this mode. Report test files created per layer + hygiene result. Overwrite (never append) `.context/ship-run/<task-id>/phase-status-test-generate.md` if the scratch dir exists:
```
| test-generate | #<RUN> | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```
`#<RUN>`: literal placeholder, orchestrator substitutes. `<gate>`: `pass` if hygiene clean, `warn` if hits remained after the 2nd cycle.

## 4. Mode: execute

No longer invoked automatically — the deterministic `test-exec.sh` step runs the suite directly. Survives only as an explicit, user-requested fallback when that step can't resolve the test command. Read `generated-tests.md` if present (group by layer) or standalone otherwise, dispatch the matching `ship-test-*` worker(s) to run exactly those files.

## 5. Mode: full (default)

Generate then execute in one pass, no manifest round-trip. Fan out per §3.2 (no `Mode:` line, no denylist) — the worker runs the full generate+execute cycle. Run the §3.3 hygiene gate. Then write `.context/ship-run/<task-id>/test-failures.md` (skip standalone): failures → `- <file> (<N> failures)`; zero → header only. Overwrite `phase-status-test.md` if the scratch dir exists (never append to shared `phase-status.md`):
```
| test | #<RUN> | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```
Report: tests created, passed, failed per layer.

## 6. Self-check before returning (MANDATORY)

1. Every `run=` layer (and, in `execute`, present in manifest) — issued a `ship-test-*` Agent call? Skipped one, or narrated with zero calls? Dispatch the missing workers now.
2. `generate`/`full`: hygiene gate actually ran and hits remediated? Unrun gate or known hits present = defect.
3. `generate`: wrote `generated-tests.md`, avoided `test-failures.md`, wrote the `phase-status-test-generate.md` row with the correct gate?
4. `execute`: user-requested fallback, not automatic — confirm the user asked before dispatching.

Returning in any unfinished state is a defect.
