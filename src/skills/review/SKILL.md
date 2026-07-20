---
name: ship:review
description: "Ship Phase 6: code review focused on SOLID, DRY, KISS, Clean Code, and project consistency."
argument-hint: "<feature-name | task-id>"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: sonnet
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

Unless `$ARGUMENTS` already carries a `## Diff` section, ensure the scratch `diff.md` is populated:

```bash
bash "@@ship/hooks/capture-diff.sh" .context/ship-run/<task-id>/diff.md --prefer .context/ship-run/<task-id>/diff.md
```

(No-op when `diff.md` already holds a valid diff; captures fresh otherwise.)

## 4. Test-failure context (passthrough)

If `.context/ship-run/<task-id>/test-failures.md` exists, read it. If it lists any modules after the `# Test Failures` header, pass them through to the agent as a `## Test Failures` section so it prioritizes reviewing those modules. If the file contains only the header (zero failures) or does not exist, pass nothing.

## 5. Invoke ship-review agent

Use the Agent tool with `subagent_type: ship:ship-review`. Resolve the absolute path of `@@ship/hooks/findings-gate.sh` and pass it inline as `Findings gate script:`. Pass all context inline in the prompt:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Stack: <stack>
Findings gate script: <absolute path resolved above>

## Config
Severity Overrides: <severity-overrides or "none">

## Test Failures
<inline: modules with failing tests, or omit if none>
```

The agent reads the diff from the scratch dir and handles the full review, findings report, the deterministic gate, and phase-status update. Return the agent's full output verbatim as your final message.
