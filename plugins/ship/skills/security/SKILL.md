---
name: ship:security
description: "Ship Phase 5: OWASP security scan of the diff with 3 parallel agents by attack category."
argument-hint: "<feature-name | task-id>"
allowed-tools: Read, Bash, Agent
model: sonnet
context: fork
---

# Ship Security — Skill Wrapper

Delegates to the `ship-security` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the task identifier or feature name.

## 2. Load minimal context

**If `$ARGUMENTS` already contains `Artifact language:`, `Storage mode:`, `Stack:`, and `Security Focus:` fields** (injected inline by the orchestrator in pipeline mode), use them directly — skip reading `ship/config.md` entirely.

**Otherwise** (standalone invocation), read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Stack` → e.g., Node.js, Next.js, NestJS
- `Security Focus → categories` → e.g., `all`, `web-api`, `mobile`, `infrastructure`, `none`
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Resolve diff

See ### Diff resolution (skill wrappers) {#diff-resolution}

Phase skills that consume the diff (`perf`, `security`, `review`, `analyze`) resolve it in the same order:

**If `$ARGUMENTS` already contains a `## Diff` section** (injected inline by the orchestrator), use it directly — skip file reads and git commands.

**Otherwise:**
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → run `git diff origin/main...HEAD` to obtain the diff (canonical range per this pattern).

## 4. Invoke ship-security agent

Use the Agent tool with `subagent_type: ship:ship-security`. Pass all context inline in the prompt:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Stack: <stack>
Security Focus: <security-focus-category>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content>
```

The agent handles Security Focus validation, OWASP category mapping, diff slicing, 3 parallel sub-agents, consolidation, report writing, and phase status update.
