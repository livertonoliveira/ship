---
name: ship:audit:tests
description: "Ship Audit: project-wide test coverage analysis — correlates AC/REQ from spec with existing tests using Jaccard similarity, gate PASS/WARN."
argument-hint: ""
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
context: fork
---

# Ship Audit Tests — Skill Wrapper

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract any Linear issue ID from `$ARGUMENTS` (e.g., `MOB-123`). May be empty for standalone runs.

`Inventory: <path>` in `$ARGUMENTS` (set by `ship:audit:run`) → forward the same line to the agent. Absent → omit it; the agent discovers files itself.

## 2. Load minimal context from `ship/config.md`

- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` section → enabled/disabled status for `unit`, `integration`, `e2e` layers
- If the `Test Scope` section is absent → treat all three layers as `enabled`

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`), # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. and ## Config fields {#stack-fields}

Read the project's stack from these `ship/config.md` fields: Runtime, Framework, Database, Frontend, Project Type (`backend` | `frontend` | `fullstack` | `monorepo`), Workspaces (monorepo only), Build tool, Test framework, Package manager, Lint command, Typecheck command..

## 3. Invoke ship-audit-tests agent

Use the Agent tool with `subagent_type: ship:ship-audit-tests`. Pass all context inline in the prompt:

```
Issue ID: <issue-id or "none">
Artifact language: <artifact_language>
Storage mode: <linear|local>
Findings gate script: ${CLAUDE_SKILL_DIR}/hooks/findings-gate.sh
Coverage script: ${CLAUDE_SKILL_DIR}/hooks/coverage-correlate.sh

## Config
Test Scope:
- unit: <enabled|disabled>
- integration: <enabled|disabled>
- e2e: <enabled|disabled>
```

The agent handles spec discovery, AC/REQ↔test correlation (via the coverage script), review of uncertain matches, gate decision, report writing, and JSON summary output. Return the agent's full output verbatim as your final message so `ship:audit:run` can read the report and JSON summary.
