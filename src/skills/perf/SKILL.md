---
name: ship:perf
description: "Ship Phase 4: performance analysis of the diff. Detects project type (monorepo/backend/frontend) and adapts agents accordingly."
argument-hint: "<feature-name | task-id>"
allowed-tools: Read, Bash, Agent
model: sonnet
context: fork
---

# Ship Perf — Skill Wrapper

Delegates to the `ship-perf` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the task identifier or feature name.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Project Type` → backend | frontend | fullstack | monorepo
- `Stack` → e.g., Node.js, Next.js, NestJS
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Resolve diff

Unless `$ARGUMENTS` already carries a `## Diff` section, ensure the scratch `diff.md` is populated:

```bash
bash "@@ship/hooks/capture-diff.sh" .context/ship-run/<task-id>/diff.md --prefer .context/ship-run/<task-id>/diff.md
```

(No-op when `diff.md` already holds a valid diff; captures fresh otherwise.) The agent reads it from the scratch dir.

## 4. Invoke ship-perf agent

Use the Agent tool with `subagent_type: ship:ship-perf`. Resolve the absolute path of `@@ship/hooks/findings-gate.sh` and pass it inline as `Findings gate script:`. Pass all context inline in the prompt:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Project Type: <project-type>
Stack: <stack>
Findings gate script: <absolute path resolved above>

## Config
Severity Overrides: <severity-overrides or "none">
```

The agent reads the diff from the scratch dir and handles strategy selection, parallel sub-agents, the deterministic gate, report writing, and phase status update.
