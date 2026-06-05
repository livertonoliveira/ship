---
name: ship:audit:security
description: "Ship Audit: project-wide AppSec audit — OWASP Top 10, CWE mapping, 4 parallel agents, A-F score, PoC for critical/high."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Audit Security — Skill Wrapper

Parse arguments and delegate to the `ship-audit-security` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.
Extract any `Security focus override` (e.g., `web-api`, `mobile`, `infrastructure`); default to `none` (no override) if absent.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Stack` → for additional context

See @ship/patterns/storage-mode.md and @ship/patterns/stack-detection.md.

## 3. Invoke ship-audit-security agent

Use the Agent tool with `subagent_type: ship:ship-audit-security`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>
Security focus override: <override or "none">

## Config
Stack: <stack>
```

The agent handles category routing, parallel sub-agents, OWASP/CWE analysis, PoC for critical/high, scoring, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
