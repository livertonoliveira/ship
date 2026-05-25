---
name: audit:backend
description: "Ship Audit: project-wide backend performance audit. Detects stack from config and launches 3 parallel agents."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Audit — Backend Skill Wrapper

Parse arguments and delegate to the `ship-audit-backend` named agent.

**Input received:** $ARGUMENTS

---

## 1. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Linear Integration → Team ID` → for Linear artifact creation
- `Project Type` → to detect if frontend-only (agent will warn and stop)
- `Stack` → runtime, framework, database
- `Severity Overrides` → downgrade rules for `backend` phase (if present)

## 2. Invoke ship-audit-backend agent

Use the Agent tool with `subagent_type: ship-audit-backend`. Pass all context inline in the prompt:

```
Artifact language: <artifact_language>
Storage mode: <linear|local>
Team ID: <team_id>

## Config
Project Type: <project-type>
Stack: <stack>
Severity Overrides: <overrides for backend phase, or "none">
```

The agent handles pre-flight checks, 3-parallel-agent analysis, report writing (local or Linear), and JSON summary output.
