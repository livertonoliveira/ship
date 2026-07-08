---
name: ship:perf
description: "Ship Phase 4: performance analysis of the diff. Detects project type (monorepo/backend/frontend) and adapts agents accordingly."
argument-hint: "<feature-name | task-id>"
allowed-tools: Read, Bash, Agent
model: haiku
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

See ### Diff resolution (skill wrappers) {#diff-resolution}

Phase skills that consume the diff (`perf`, `security`, `review`, `analyze`) resolve it in the same order:

**If `$ARGUMENTS` already contains a `## Diff` section** (injected inline by the orchestrator), use it directly — skip file reads and git commands.

**Otherwise:**
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → run `git diff origin/main...HEAD` to obtain the diff (canonical range per this pattern).

## 4. Invoke ship-perf agent

Use the Agent tool with `subagent_type: ship:ship-perf`. Pass all context inline in the prompt:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Project Type: <project-type>
Stack: <stack>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content>
```

The agent handles strategy selection, parallel sub-agents, consolidation, report writing, and phase status update.
