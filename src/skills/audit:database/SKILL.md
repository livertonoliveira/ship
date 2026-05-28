---
name: ship:audit:database
description: "Ship Audit: project-wide database audit. Routes to MongoDB, PostgreSQL, or MySQL methodology based on ship/config.md. 3 parallel agents."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Audit Database — Skill Wrapper

Parse arguments and delegate to the `ship-audit-database` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Database` → MongoDB | PostgreSQL | MySQL | SQLite | none
- `Stack` → for additional context

See @ship/patterns/storage-mode.md and @ship/patterns/stack-detection.md.

## 3. Invoke ship-audit-database agent

Use the Agent tool with `subagent_type: ship:ship-audit-database`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>

## Config
Database: <database-type>
Stack: <stack>
```

The agent handles engine routing, 3-agent parallel execution, findings consolidation, report writing, and JSON summary output.
