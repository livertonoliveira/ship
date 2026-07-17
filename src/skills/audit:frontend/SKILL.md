---
name: ship:audit:frontend
description: "Ship Audit: project-wide frontend performance audit. Auto-routes to Next.js methodology (5 layers) or generic methodology (11 categories) based on ship/config.md."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
context: fork
---

# Ship Audit Frontend — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Frontend` → framework (Next.js, React, Vue, Angular, Svelte, ...)
- `Project Type` → backend | frontend | fullstack | monorepo
- `Stack` → runtime, build tool, package manager

See @ship/patterns/storage-mode.md and @ship/patterns/stack-detection.md.

Routing hint (decides nothing — the agent owns the final routing): if `Frontend: Next.js` or a `next.config.*` file exists at the project root, the agent uses the Next.js path (5 heuristics); otherwise the generic path (11 categories).

## 3. Invoke ship-audit-frontend agent

Use the Agent tool with `subagent_type: ship:ship-audit-frontend`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>

## Stack
Frontend: <framework>
Project Type: <type>
Stack: <stack>

## Config
<severity overrides if present>
```

The agent handles framework routing, heuristic selection, parallel sub-agents, consolidation, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
