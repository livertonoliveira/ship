---
name: ship:audit:tests
description: "Ship Audit: project-wide test coverage analysis — correlates AC/REQ from spec with existing tests using Jaccard similarity, gate PASS/WARN."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Audit Tests — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` section → enabled/disabled status for `unit`, `integration`, `e2e` layers
- If the `Test Scope` section is absent → treat all three layers as `enabled`

See @ship/patterns/storage-mode.md, @ship/patterns/load-artifacts.md and @ship/patterns/stack-detection.md.

## 3. Invoke ship-audit-tests agent

Use the Agent tool with `subagent_type: ship:ship-audit-tests`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>

## Config
Test Scope:
- unit: <enabled|disabled>
- integration: <enabled|disabled>
- e2e: <enabled|disabled>
```

The agent handles AC/REQ↔test correlation (Jaccard), gap classification by layer, gate decision, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
