---
name: audit:frontend
description: "Ship Audit: project-wide frontend performance audit. Auto-routes to Next.js methodology (5 heuristics) or generic methodology (11 categories) based on ship/config.md."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Audit Frontend — Skill Wrapper

Parse arguments and delegate to the `ship-audit-frontend` named agent.

**Input received:** $ARGUMENTS

---

## 1. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Frontend` → framework (Next.js, React, Vue, etc.)
- `Project Type` → backend | frontend | fullstack | monorepo
- `Stack` → runtime, build tool, package manager (full stack summary)
- `Severity Overrides` → downgrade rules (if present)

## 2. Detect framework (fallback)

If `ship/config.md` is absent or has no `Frontend` field, probe the project root:
- `next.config.*` exists → Next.js
- Otherwise → generic

## 3. Invoke ship-audit-frontend agent

Use the Agent tool with `subagent_type: ship-audit-frontend`. Pass all context inline in the prompt:

```
Artifact language: <artifact_language>
Storage mode: <linear|local>
Framework: <Next.js | React | Vue | ...>
Project Type: <project-type>
Stack: <runtime, build tool, package manager>

## Config
Severity Overrides: <severity-overrides or "none">
```

The agent handles auto-routing (Next.js 5-heuristic vs generic 11-category), launches 3 parallel sub-agents, consolidates findings, writes the report, creates Linear artifacts (Linear mode), and emits the machine-readable JSON summary.
