---
name: ship:audit:backend
description: "Ship Audit: project-wide backend performance audit. Detects stack from config and launches 3 parallel agents."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
context: fork
---

# Ship Audit Backend — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Linear Integration → Team ID` → for Linear mode artifacts
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Project Type` → backend | fullstack | monorepo (warn and stop if `frontend`)
- `Stack` → for additional context

See @ship/patterns/storage-mode.md and @ship/patterns/stack-detection.md.

## 3. Invoke ship-audit-backend agent

Use the Agent tool with `subagent_type: ship:ship-audit-backend`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>
Team ID: <team-id or "none">

## Config
Project Type: <project-type>
Stack: <stack>
```

The agent handles strategy selection, parallel sub-agents, findings consolidation, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
