---
name: ship:review
description: "Ship Phase 6: code review focused on SOLID, DRY, KISS, Clean Code, and project consistency."
argument-hint: "<feature-name | task-id>"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Review — Skill Wrapper

Delegates to the `ship-review` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the task identifier or feature name.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Stack` → e.g., Node.js, Next.js, NestJS
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Resolve diff

See @ship/patterns/run-context.md#diff-resolution.

## 4. Test-failure context (passthrough)

If `.context/ship-run/<task-id>/test-failures.md` exists, read it. If it lists any modules after the `# Test Failures` header, pass them through to the agent as a `## Test Failures` section so it prioritizes reviewing those modules. If the file contains only the header (zero failures) or does not exist, pass nothing.

## 5. Invoke ship-review agent

Use the Agent tool with `subagent_type: ship:ship-review`. Pass all context inline in the prompt:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Stack: <stack>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content>

## Test Failures
<inline: modules with failing tests, or omit if none>
```

The agent handles the full review, findings report, gate decision, and phase-status update. Return the agent's full output verbatim as your final message.
