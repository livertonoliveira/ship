---
name: develop
description: "Ship Phase 2: implements code following project conventions, with parallel agents for independent modules."
argument-hint: "<task-id | linear-issue-id>"
allowed-tools: Read, Agent, mcp__linear-server__*
user-invocable: true
model: haiku
context: fork
---

# Ship Develop — Skill Wrapper

Parse arguments and delegate to the `ship-develop` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the task identifier from `$ARGUMENTS` (e.g., `MOB-1554` or a local feature slug).

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Load spec context

**If `$ARGUMENTS` already contains a `## Design` section** (injected inline by the orchestrator), skip `list_documents` + `get_document` — use the inline content directly.

**Otherwise (standalone invocation or no inline Design):**

**Linear mode:** call `mcp__linear-server__get_issue` to fetch the issue title and description. Call `mcp__linear-server__list_documents` + `mcp__linear-server__get_document` to get the Design document.

**Local mode:** read `ship/changes/<feature>/proposal.md`, `design.md`, `tasks.md`.

## 4. Invoke ship-develop agent

Use the Agent tool with `subagent_type: ship-develop`. Pass all context inline in the prompt:

```
Task: <task-id> — <title>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>

## Spec
<inline: issue description + ACs>

## Design
<inline: full design document content>
```

The agent handles implementation, parallelism, typecheck, and artifact updates.
