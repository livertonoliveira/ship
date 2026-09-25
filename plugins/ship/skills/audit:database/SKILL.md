---
name: ship:audit:database
description: "Ship Audit: project-wide database audit. Routes to MongoDB, PostgreSQL, or MySQL methodology based on ship/config.md. 3 parallel agents."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
context: fork
---

# Ship Audit Database — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

`Inventory: <path>` in `$ARGUMENTS` (set by `ship:audit:run`) → forward the same line to the agent. Absent → omit it; the agent discovers files itself.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Database` → MongoDB | PostgreSQL | MySQL | SQLite | none
- `Stack` → for additional context

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`) and ## Config fields {#stack-fields}

Read the project's stack from these `ship/config.md` fields: Runtime, Framework, Database, Frontend, Project Type (`backend` | `frontend` | `fullstack` | `monorepo`), Workspaces (monorepo only), Build tool, Test framework, Package manager, Lint command, Typecheck command..

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

The agent handles engine routing, 3-agent parallel execution, findings consolidation, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
