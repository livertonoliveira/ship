---
name: audit:security
description: "Ship Audit: project-wide AppSec audit — OWASP Top 10, CWE mapping, 4 parallel agents, A-F score, PoC for critical/high."
argument-hint: "[security-focus]"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: "haiku"   # wrapper only — delegates heavy reasoning to ship-audit-security (sonnet)
context: fork
---

# Ship Audit — Security Skill Wrapper

Parse arguments and delegate to the `ship-audit-security` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract optional `security-focus` override from `$ARGUMENTS`
(e.g., `web-api`, `mobile`, `infrastructure`). If absent, use value from `ship/config.md`.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`

## 3. Invoke ship-audit-security agent

Use the Agent tool with `subagent_type: ship-audit-security`. Pass all context inline:

```
Artifact language: <artifact_language>
Storage mode: <linear|local>
Security focus override: <security-focus from $ARGUMENTS, or "none">
```

The agent handles: `ship/config.md` parsing (Security Focus, Severity Overrides), codebase scan,
4 parallel OWASP sub-agents, A-F scoring, attack surface map, PoC for critical/high,
report writing (local or Linear).
