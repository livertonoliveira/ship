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

You are the Ship test orchestrator. Read Test Scope, resolve scenarios by layer, fan out to named agents in parallel.

> **CRITICAL — you MUST act, not narrate.** You have no Edit/Write tools; the ONLY way tests get written or run is by dispatching `ship-test-*` workers through the **Agent tool**. Describing which tests "would be generated", summarizing a plan, or returning a status without having issued the Agent tool calls is a **hard failure** of this skill, not a shortcut. If you finish your turn having narrated a test plan but issued **zero** Agent tool calls for the enabled layers, you have failed. Resolve the layers, then immediately dispatch.

**Input received:** $ARGUMENTS (task ID as the first token, followed by an optional `Mode:` line, artifact language, scenarios, and modified files — passed by the orchestrator when invoked from `ship:run`)

## 1. Load context

Parse `$ARGUMENTS`: extract `task-id` from the first whitespace-delimited token. Use this value wherever `<task-id>` appears below. If no task-id is present (standalone invocation), derive it from the current branch name or use `standalone` as the fallback.

Parse the `Mode:` line if present. Valid values: `generate`, `execute`, `full`. If absent, the mode is `full` — this is the default and preserves the exact single-pass behavior this skill has always had.

Read `ship/config.md`: extract `## Test Scope` (which layers are active) and `Artifact language`. If section absent, default all layers to `enabled`.

Read `.context/ship-run/<task-id>/stack.md` if it exists (fallback: `ship/config.md`).

**Read the plan:** if `.context/ship-run/<task-id>/plan.md` exists, read its `## Test Contract` section. Each entry (`@SC-XX -> <layer> -> <test file>` with `arrange/act/assert`) is the concrete test slot already mapped from the scenario by `ship:plan` — the same single interpretation `ship:develop` built code from. Pass each layer's slots to its worker (step 3) so code and tests stay derived from one source instead of two independent reads. If `plan.md` is absent (planner skipped for a `minor`/`trivial` diff, or standalone), fall back to the raw scenarios below.

**If `## Scenarios` was NOT injected inline by the orchestrator** — parse the task's `## Scenarios` Gherkin block from artifacts:
- **Linear mode**: read the issue body via MCP (`mcp__linear-server__get_issue`). If MCP tools are not available (this orchestrator's `allowed-tools` does not include MCP), skip Linear and fall back to local mode — log a warning: `"WARNING: MCP unavailable — falling back to proposal.md for ACs"`.
- **Local mode** (or MCP unavailable): read `ship/changes/<feature>/proposal.md` and extract the `## Acceptance Criteria` section as the scenario source.

Group scenarios by their declared `@layer` tag — do NOT re-classify. Log:
```
Test layers: unit=<enabled|disabled>, integration=<enabled|disabled>, e2e=<enabled|disabled>
Mode: <generate|execute|full>
```

## 2. Guard — all layers disabled

If all layers are `disabled`: output "Fase de testes pulada — todos os layers estão desabilitados em `Test Scope` (ship/config.md). Habilite ao menos um layer para gerar testes." Then stop.

This guard applies to every mode.

---

## 3. Mode: generate

Generation-only pass: writes test files, never runs a test command, never writes `test-failures.md`.

### 3.1 Resolve the denylist

Read `.context/ship-run/<task-id>/plan.md` (if present) and collect every file path listed across all modules' file sets — these are the source files owned by `ship:develop`. This is the `## Denylist` injected into every worker below. If `plan.md` is absent, the denylist is empty (standalone invocation has no module boundary to protect).

### 3.2 Fan out to named agents (parallel) — MANDATORY ACTION

This section reuses the shared fan-out mechanics below (§3.2a), adding only the `generate`-specific prompt fields and instructions.

#### 3.2a Shared fan-out mechanics (used by `generate` and `full`)

| Layer | subagent_type |
|-------|---------------|
| unit | ship:ship-test-unit |
| integration | ship:ship-test-integration |
| e2e | ship:ship-test-e2e |

For each enabled layer, launch the agent via the Agent tool using `subagent_type`. Skip disabled layers (log `Skipping [layer] tests (disabled in Test Scope)`).

**Context slicing — always pass inline, never rely on the agent to re-read:**
1. Filter scenarios: keep only those tagged `@unit`, `@integration`, or `@e2e` for the respective agent. Never pass the full list to all agents.
2. Resolve the diff **once** here (not inside each agent) and pass it inline as `## Source`. Never use `git diff origin/main...HEAD` (three-dot) — it compares only **committed** history and is **empty** mid-pipeline (`ship:develop` writes to the working tree without committing). Instead: in **pipeline mode**, read the authoritative `.context/ship-run/<task-id>/diff.md` the orchestrator refreshed after develop (do not recompute); in **standalone** mode, run `BASE=$(git merge-base origin/main HEAD); git add -A -N; git diff "$BASE"` to capture the working tree incl. untracked files.
3. Structure each agent's prompt with explicit sections (mode-specific fields are listed in §3.2 / §5.1):
   ```
   Task ID: <task-id>
   Artifact language: <language>

   ## Test Contract
   <the @SC-XX -> layer -> file slots for THIS layer from plan.md; omit if no plan>

   ## Scenarios
   <filtered Gherkin for this layer>

   ## Files
   <list of modified files from git diff>

   ## Source
   <relevant diff content or file excerpts>
   ```
   When `## Test Contract` is present, the worker uses those mapped slots (file + arrange/act/assert) as the source of truth and treats `## Scenarios` as the behavioral reference behind them.
4. **De-identify before injecting.** Strip the spec-ID tags/tokens from `## Scenarios` and `## Test Contract`, keeping the behavioral steps — so the worker cannot echo an ID it never received. Keep the `SC-XX → test file` mapping in your own notes for the report.

   @ship/patterns/deidentify-context.md
5. Agents that receive these sections inline MUST NOT fall back to standalone discovery mode.

If some (not all) layers are disabled, after skip logs output: "Layers pulados por configuração: [&lt;list&gt;]. Para habilitá-los, edite `Test Scope` em `ship/config.md`."

#### 3.2b Mode-specific delta for `generate`

Add `Mode: generate` right after `Task ID:` in the prompt, and append a `## Denylist` section after `## Source`:
```
## Denylist
<the module file sets from plan.md — paths this worker must never create or modify>
```
Instruct the worker explicitly: generate the test file(s) only — do not run any test command, do not report pass/fail counts.

### 3.3 Hygiene gate — final sweep (MANDATORY)

Run the scan now — this is a mandatory Bash call, not optional:

```bash
bash "@@ship/hooks/hygiene-scan.sh" --all 2>&1
```

If the output contains hits:
1. Dispatch a cleanup worker for each flagged file via the Agent tool with `Mode: clean`, using the matching type (`ship:ship-test-unit` / `ship:ship-test-integration` / `ship:ship-test-e2e`). Pass the exact `file:line` hits.
2. Re-run the scan above. If hits remain after a second cycle, record them in the phase report and surface as `warn` — never report PASS while known hits remain.

If output is `Ship hygiene — clean.` → proceed.

### 3.4 Write the manifest

Collect the list of test files each worker reported as created, grouped by layer. Write `.context/ship-run/<task-id>/generated-tests.md`:

```markdown
# Generated Tests

- src/auth/auth.service.spec.ts (unit)
- src/auth/auth.controller.spec.ts (integration)
```

Header-only file if no worker created any file for a layer — only list what was actually created; do not pre-populate expected paths.

Do **NOT** write `test-failures.md` in this mode.

### 3.5 Write phase-status-test-generate.md

Write (overwrite, do not append) `.context/ship-run/<task-id>/phase-status-test-generate.md` if the scratch dir exists (skip in standalone mode) — never write directly to the shared `phase-status.md`, since this mode runs concurrently with `ship:develop` in the same turn (Phase 2 overlap) and a concurrent append would race:
```
| test-generate | #<RUN> | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```
Leave `#<RUN>` as a literal placeholder — the orchestrator substitutes the real run number when it consolidates this row into `phase-status.md`.

`<gate>` reflects the §3.3 hygiene-gate outcome: `pass` if the scan was clean on the first pass or clean after remediation; `warn` if hits remained after the second cycle.

### 3.6 Report

Report to the caller: the list of test files created per layer (from the manifest), and the hygiene gate result.

---

## 4. Mode: execute

Execution-only pass: never generates anything, always consumes a manifest from a prior `generate` run.

### 4.1 Read the manifest

Read `.context/ship-run/<task-id>/generated-tests.md`. Group its entries by layer. If the file is absent or header-only for every enabled layer, there is nothing to execute — report that generation must run first and stop.

### 4.2 Fan out to named agents (parallel) — MANDATORY ACTION

For each layer that both (a) has files listed in the manifest and (b) is enabled in Test Scope, dispatch the corresponding worker:

| Layer | subagent_type |
|-------|---------------|
| unit | ship:ship-test-unit |
| integration | ship:ship-test-integration |
| e2e | ship:ship-test-e2e |

Prompt structure:
```
Task ID: <task-id>
Mode: execute
Artifact language: <language>

## Test Files
<the list of test files for this layer from generated-tests.md>
```

The worker runs the suite against exactly those files (no generation), applying the existing fix-up-to-2-iterations cycle on failures.

Skip layers with no entries in the manifest or disabled in Test Scope (log accordingly, same messaging as the generate/full fan-out).

### 4.3 Hygiene gate — fix-iteration sweep (MANDATORY if any worker fixed a file)

A fix iteration in §4.2 can edit test files, reintroducing comments or spec IDs. If any worker reported edits during its fix cycle, run the hygiene scan scoped to exactly those edited files (not the whole manifest):

```bash
bash "@@ship/hooks/hygiene-scan.sh" <edited-file-1> <edited-file-2> ... 2>&1
```

If the output contains hits, remediate the same way as §3.3: dispatch a cleanup worker per flagged file via the Agent tool with `Mode: clean`, using the matching type, then re-run the scoped scan. If hits remain after a second cycle, record them and surface `warn`.

If no worker performed a fix edit in this run, skip this step entirely.

### 4.4 Consolidate and write test-failures.md

After agents complete, write `.context/ship-run/<task-id>/test-failures.md` (skip in standalone mode):
- Failures present → list them: `- <file> (<N> failures)`
- Zero failures → header only: `# Test Failures`

Write (overwrite, do not append) `.context/ship-run/<task-id>/phase-status-test.md` if the scratch dir exists — never write directly to the shared `phase-status.md`:
```
| test | #<RUN> | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```
Leave `#<RUN>` as a literal placeholder — the orchestrator substitutes the real run number when it consolidates this row into `phase-status.md`.

Report to the user: passed and failed counts per layer.

---

## 5. Mode: full (default)

Identical to the original single-pass behavior: generate then execute in one continuous pass, with no manifest round-trip required.

### 5.1 Fan out to named agents (parallel) — MANDATORY ACTION

This is the step where tests get written and run. You **must** issue real Agent tool calls here, one per enabled layer. Do not return to the caller until you have actually dispatched a worker for every enabled layer.

This section reuses the shared fan-out mechanics from §3.2a (layer table, context-slicing rules, skip logging) — no mode-specific delta beyond the prompt fields already defined there. The worker receives the full `generate` + `execute` cycle in one continuous pass (no `Mode:` line needed, no manifest round-trip).

### 5.2 Hygiene gate — final sweep (MANDATORY)

This reuses §3.3 verbatim — run the same scan, same remediation loop (dispatch `Mode: clean` on hits, re-run, surface `warn` if hits remain after a second cycle).

### 5.3 Consolidate and write test-failures.md

This reuses §4.4 verbatim — write `.context/ship-run/<task-id>/test-failures.md`, write the `phase-status-test.md` row, and report tests created, passed, and failed per layer.

---

## 6. Self-check before returning (MANDATORY)

Before you end your turn, verify out loud:
1. For every layer marked `enabled` in Test Scope (and, in `execute` mode, present in the manifest), did you actually issue a `ship-test-*` Agent tool call? If you skipped an eligible layer without dispatching, or you reach the end having narrated a test plan with **zero** Agent tool calls, you are not done — dispatch the missing workers now.
2. In `generate` and `full` modes: did the hygiene gate actually run, and did you remediate any hits it found? Reporting success with an unrun gate — or with known comment/spec-ID hits still in test files — is a defect.
3. In `generate` mode: did you write `generated-tests.md`, avoid writing `test-failures.md`, and write the `phase-status-test-generate.md` row (§3.5) with the correct gate?
4. In `execute` mode: if any fix iteration edited a test file, did the scoped hygiene sweep (§4.3) run over those files? Did you write `test-failures.md` in the canonical format?

Returning in any unfinished state is a defect.
