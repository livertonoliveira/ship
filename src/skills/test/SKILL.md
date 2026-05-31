---
name: ship:test
description: "Ship Phase 3: fan-out orchestrator — only layers enabled in Test Scope are launched."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
user-invocable: true
model: "haiku"
context: fork
agent: general-purpose
---

# Ship Test — Fan-out Orchestrator

You are the Ship test orchestrator. Read Test Scope, resolve scenarios by layer, fan out to named agents in parallel.

**Input received:** $ARGUMENTS (task ID as the first token, followed by artifact language, scenarios, and modified files — passed by the orchestrator when invoked from `ship:run`)

## 1. Load context

Parse `$ARGUMENTS`: extract `task-id` from the first whitespace-delimited token. Use this value wherever `<task-id>` appears below. If no task-id is present (standalone invocation), derive it from the current branch name or use `standalone` as the fallback.

Read `ship/config.md`: extract `## Test Scope` (which layers are active) and `Artifact language`. If section absent, default all layers to `enabled`.

Read `.context/ship-run/<task-id>/stack.md` if it exists (fallback: `ship/config.md`).

**Read the plan:** if `.context/ship-run/<task-id>/plan.md` exists, read its `## Test Contract` section. Each entry (`@SC-XX -> <layer> -> <test file>` with `arrange/act/assert`) is the concrete test slot already mapped from the scenario by `ship:plan` — the same single interpretation `ship:develop` built code from. Pass each layer's slots to its worker (step 3) so code and tests stay derived from one source instead of two independent reads. If `plan.md` is absent (planner skipped for a `minor`/`trivial` diff, or standalone), fall back to the raw scenarios below.

**If `## Scenarios` was NOT injected inline by the orchestrator** — parse the task's `## Scenarios` Gherkin block from artifacts:
- **Linear mode**: read the issue body via MCP (`mcp__linear-server__get_issue`). If MCP tools are not available (haiku has no MCP in `allowed-tools`), skip Linear and fall back to local mode — log a warning: `"WARNING: MCP unavailable — falling back to proposal.md for ACs"`.
- **Local mode** (or MCP unavailable): read `ship/changes/<feature>/proposal.md` and extract the `## Acceptance Criteria` section as the scenario source.

Group scenarios by their declared `@layer` tag — do NOT re-classify. Log:
```
Test layers: unit=<enabled|disabled>, integration=<enabled|disabled>, e2e=<enabled|disabled>
```

## 2. Guard — all layers disabled

If all layers are `disabled`: output "Fase de testes pulada — todos os layers estão desabilitados em `Test Scope` (ship/config.md). Habilite ao menos um layer para gerar testes." Then stop.

## 3. Fan out to named agents (parallel)

For each enabled layer, launch the agent via the Agent tool using `subagent_type`. Skip disabled layers (log `Skipping [layer] tests (disabled in Test Scope)`).

| Layer | subagent_type |
|-------|---------------|
| unit | ship:ship-test-unit |
| integration | ship:ship-test-integration |
| e2e | ship:ship-test-e2e |

**Context slicing — always pass inline, never rely on the agent to re-read:**
1. Filter scenarios: keep only those tagged `@unit`, `@integration`, or `@e2e` for the respective agent. Never pass the full list to all agents.
2. Run `git diff origin/main...HEAD` **once** here (not inside each agent) and pass the resulting diff inline as `## Source`.
3. Structure each agent's prompt with explicit sections:
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
4. Agents that receive these sections inline MUST NOT fall back to standalone discovery mode.

Pass inline in each agent's prompt: `Artifact language`, `## Scenarios` subset for the layer, list of modified files, task ID.

If some (not all) layers are disabled, after skip logs output: "Layers pulados por configuração: [&lt;list&gt;]. Para habilitá-los, edite `Test Scope` em `ship/config.md`."

## 4. Consolidate and write test-failures.md

After agents complete, write `.context/ship-run/<task-id>/test-failures.md` (skip in standalone mode):
- Failures present → list them: `- <file> (<N> failures)`
- Zero failures → header only: `# Test Failures`

Append to `.context/ship-run/<task-id>/phase-status.md` if it exists:
```
| test | #<RUN_NUM> | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```
Derive `RUN_NUM` dynamically: count existing `| test |` rows in the file and add 1.
Example: `RUN_NUM=$(grep -c '^| test |' .context/ship-run/<task-id>/phase-status.md 2>/dev/null || echo 0); RUN_NUM=$((RUN_NUM + 1))`

Report to the user: tests created, passed, and failed per layer.
