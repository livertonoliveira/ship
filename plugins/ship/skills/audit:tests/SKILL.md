---
name: audit:tests
description: "Ship Audit: project-wide test coverage analysis — correlates AC/REQ from spec with existing tests using Jaccard similarity, gate PASS/WARN."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Audit Tests — Skill Wrapper

Parse arguments and delegate to the `ship-audit-tests` named agent.

**Input received:** $ARGUMENTS

---

## 1. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Linear Integration → Team ID` → required for Linear mode (use `"none"` if local mode)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` → enabled/disabled state per layer (default all enabled if section absent)

## 2. Invoke ship-audit-tests agent

Use the Agent tool with `subagent_type: ship-audit-tests`. Pass all context inline in the prompt:

```
Artifact language: <artifact_language>
Storage mode: <linear|local>

## Config
Test Scope: <unit: enabled|disabled, integration: enabled|disabled, e2e: enabled|disabled>
Linear Team ID: <team-id or "none">
```

The agent handles parallel AC/REQ and test discovery, Jaccard correlation, report generation (local file or Linear artifacts), and JSON summary output.
