---
name: ship:analyze
description: "Ship Phase 6.5: drift detection — maps spec→code→tests, detects gaps, gate PASS/WARN/FAIL."
argument-hint: "<feature-name | linear-issue-id>"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Analyze — Skill Wrapper

Delegates to the `ship-analyze` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the feature name or Linear issue ID:
- A Linear issue ID (e.g., `MOB-123`) → spec is loaded from Linear.
- A feature name → spec is loaded from `ship/changes/<feature>/`.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` → enabled/disabled state per layer (`unit`, `integration`, `e2e`); absent → treat all as enabled
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Resolve diff and spec

**If `$ARGUMENTS` already contains `## Diff` / `## Spec` sections** (injected inline by the orchestrator), use them directly — skip file reads, git commands, and Linear lookups.

**Otherwise:**

Diff: see @ship/patterns/run-context.md#diff-resolution.

Spec:
- Linear mode → loaded by the agent from the Linear issue + Proposal/Design documents (issue body carries the full Gherkin `## Scenarios`).
- Local mode → loaded by the agent from `ship/changes/<feature>/proposal.md`, `design.md`, and `tasks.md`.

## 4. Invoke ship-analyze agent

Use the Agent tool with `subagent_type: ship:ship-analyze`. Pass all context inline in the prompt:

```
Task: <task-id or feature-name>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Test Scope: <e.g., { unit: enabled, integration: disabled, e2e: disabled }>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content, or note "read from scratch dir / git" if not resolved here>

## Spec
<inline: spec reference — Linear issue ID or local feature path>
```

The agent orchestrates the 2 parallel extraction agents, runs the Jaccard correlation engine, classifies gaps, writes the drift report, and returns the gate decision. Return the agent's full output verbatim as your final message.
