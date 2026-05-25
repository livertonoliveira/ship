---
name: test
description: "Ship Phase 3: generates and runs tests (unit, integration, e2e) with 3 parallel agents."
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

Parse the task's `## Scenarios` Gherkin block (Linear: issue body; local: `tasks.md`). Group scenarios by their declared `@layer` tag — do NOT re-classify. Log:
```
Test layers: unit=<enabled|disabled>, integration=<enabled|disabled>, e2e=<enabled|disabled>
```

## 2. Guard — all layers disabled

If all layers are `disabled`: output "Fase de testes pulada — todos os layers estão desabilitados em `Test Scope` (ship/config.md). Habilite ao menos um layer para gerar testes." Then stop.

## 3. Fan out to named agents (parallel)

For each enabled layer, launch the agent via the Agent tool using `subagent_type`. Skip disabled layers (log `Skipping [layer] tests (disabled in Test Scope)`).

| Layer | subagent_type |
|-------|---------------|
| unit | ship-test-unit |
| integration | ship-test-integration |
| e2e | ship-test-e2e |

**Context slicing — always pass inline, never rely on the agent to re-read:**
1. Filter scenarios: keep only those tagged `@unit`, `@integration`, or `@e2e` for the respective agent. Never pass the full list to all agents.
2. Run `git diff origin/main...HEAD` **once** here (not inside each agent) and pass the resulting diff inline as `## Source`.
3. Structure each agent's prompt with explicit sections:
   ```
   Task ID: <task-id>
   Artifact language: <language>

   ## Scenarios
   <filtered Gherkin for this layer>

   ## Files
   <list of modified files from git diff>

   ## Source
   <relevant diff content or file excerpts>
   ```
4. Agents that receive these sections inline MUST NOT fall back to standalone discovery mode.

Pass inline in each agent's prompt: `Artifact language`, `## Scenarios` subset for the layer, list of modified files, task ID.

If some (not all) layers are disabled, after skip logs output: "Layers pulados por configuração: [&lt;list&gt;]. Para habilitá-los, edite `Test Scope` em `ship/config.md`."

## 4. Consolidate and write test-failures.md

After agents complete, write `.context/ship-run/<task-id>/test-failures.md` (skip in standalone mode):
- Failures present → list them: `- <file> (<N> failures)`
- Zero failures → header only: `# Test Failures`

Append to `.context/ship-run/<task-id>/phase-status.md` if it exists:
```
| test | #1 | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```

Report to the user: tests created, passed, and failed per layer.
