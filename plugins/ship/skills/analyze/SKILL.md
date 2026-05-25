---
name: analyze
description: "Ship Phase 6.5: drift detection — maps spec→code→tests, detects gaps, gate PASS/WARN/FAIL."
argument-hint: "<feature-name | linear-issue-id>"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Analyze — Skill Wrapper

Parse arguments and delegate to the `ship-analyze` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the task identifier (Linear issue ID like `MOB-123`) or local feature name from `$ARGUMENTS`.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` → enabled/disabled state per layer (default all enabled if section absent)
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`.

## 3. Resolve diff

**If `$ARGUMENTS` already contains a `## Diff` section** (injected inline by the orchestrator), use it directly — skip file reads and git commands.

**Otherwise:**

- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred).
- Otherwise → run `git diff origin/main...HEAD` to obtain the diff (canonical range per run-context).

## 4. Invoke ship-analyze agent

Use the Agent tool with `subagent_type: ship-analyze`. Pass all context inline in the prompt:

```
Task: <task-id-or-feature-name>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>

## Config
Test Scope: <unit: enabled|disabled, integration: enabled|disabled, e2e: enabled|disabled>
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content>
```

The agent handles spec/code/test extraction (parallel sub-agents), Jaccard correlation, report generation, gate computation, persistence (scratch dir + Linear comment or local file), and phase-status append.
