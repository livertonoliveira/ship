---
name: ship:init
description: "Initializes Ship in the project: detects stack, conventions, configures Linear, and creates ship/config.md."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Init — Initial Project Setup

You are the Ship initialization agent. Analyze the project and create the base config all other Ship commands read from.

---

## What to do

### 1. Check if already initialized

Check if `ship/config.md` exists at project root.
- Exists: ask if the user wants to reconfigure. If yes, read the file and **preserve `Test Scope`, `Scenario Depth`, `Clarify`** — pre-populate the prompt with existing values, don't overwrite.
- Missing: proceed.

### 2. Explore the project (2 agents in parallel)

Launch 2 agents in parallel via the Agent tool, both with `model: "sonnet"` explicitly (reasoning work). Orchestrator itself runs on Sonnet per ${CLAUDE_SKILL_DIR}/patterns/model-routing.md.

**Agent A — Stack Detection:** detect Runtime, Framework, Database, Frontend, Package Manager, Test Framework, Typecheck, Lint, Monorepo (workspace→type+framework), Project type (`backend`/`frontend`/`fullstack`/`monorepo`). Heuristics/signal-file table: ${CLAUDE_SKILL_DIR}/patterns/stack-detection.md — use it, don't re-derive.

**Agent B — Conventions Detection:** naming (files/vars/classes/functions), folder structure, test patterns (location/naming/helpers), import style (barrels/aliases/relative), error-handling, commit style (`git log`), any existing CLAUDE.md/docs.

### 3. Check Linear integration

- Probe with `mcp__linear-server__list_teams`.
- Connected: fetch Team ID and labels via `list_teams`/`list_issue_labels`. Call `list_issue_statuses`; record the workflow-state **names** whose `type` is `started`/`completed` (e.g. "In Progress"/"Em andamento", "Done"/"Concluído") as `In Progress Status`/`Done Status` so the pipeline never hardcodes state names. If several states share a type, prefer the conventional name; else take the first.
- Not connected: record "not configured".

### 4. Synthesize and create artifacts

Create `ship/`, `ship/changes/`, `ship/changes/archive/`, `ship/audits/`, and `ship/config.md`:

```markdown
# Ship — Project Configuration

## Stack
- Runtime: [detected]
- Framework: [detected]
- Database: [detected or "none"]
- Frontend: [detected or "none"]
- Package Manager: [detected]
- Test Framework: [detected]
- Typecheck: [detected command or "none"]
- Lint: [detected command or "none"]

## Project Type
[backend | frontend | fullstack | monorepo]

### Workspaces (if monorepo)
- [workspace-path] — [type] ([framework])

## Conventions
- File naming: [detected pattern]
- Test location: [detected pattern]
- Import style: [detected pattern]
- Error handling: [detected pattern]
- Commit style: [detected pattern]
- artifact_language: [e.g. pt-BR | en]
- prompt_language: [e.g. pt-BR | en]
- code_language: en

## Pipeline Phases
- dev: enabled
- test: enabled
- perf: enabled
- security: enabled
- review: enabled
- homolog: enabled
- pr: enabled

## Test Scope
# disabled layers skip pipeline gen; backfill via /ship:audit:tests
- unit: [default based on project type]
- integration: [default based on project type]
- e2e: [default based on project type]

## Scenario Depth
# none=no Scenarios; light=1/AC (nominal+error); full=nominal+edge+error/AC
- depth: full

## Clarify
# on=ask up to 5 ranked questions before spec; off=skip
- mode: on

## Linear Integration
- Configured: [yes | no]
- Team ID: [ID or "not configured"]
- In Progress Status: [started-state name, or "not configured"]
- Done Status: [completed-state name, or "not configured"]
- Default Labels: [detected labels or "none"]

## Pipeline Profile
- profile: standard

## Security Focus
- categories: all

## Severity Overrides
[empty by default — e.g. `high → warn` to downgrade a finding before gate evaluation]

## Gate Behavior
- on_fail: ask
- on_warn: ask
- on_fail_rerun: surgical

## Rules
[project-specific rules discovered — extended over time]
```

**Test Scope defaults by project type** — substitute the `[default based on project type]` placeholders with:
- `prompt-toolkit`/library: unit=enabled, integration=disabled, e2e=disabled
- `backend`/`fullstack`: unit=enabled, integration=enabled, e2e=disabled
- `frontend`: unit=enabled, integration=disabled, e2e=disabled
- `monorepo`: unit=enabled, integration=enabled, e2e=disabled
- unrecognized: unit=enabled, integration=disabled, e2e=disabled

`Scenario Depth → depth` and `Clarify → mode` default to `full` and `on` respectively for **all** project types — override only if the user changes them in step 5.

Preservation rule from step 1 applies here too: never overwrite existing `Test Scope`/`Scenario Depth`/`Clarify` values with these defaults.

**Gate Behavior options:**
- `on_fail` (critical/high): `ask`=prompt before fixing (default), `fix`=auto-fix without asking, `defer`=create tracking issues and continue
- `on_warn` (medium): `ask`=prompt before fixing (default), `fix`=auto-fix without asking, `pass`=continue without fixing

### 5. Ask interactive configuration questions

Present all at once, in one block, wait for a single reply. Skip any question whose section already exists in `ship/config.md` (note: "already configured — preserving existing value").

1. **Gate behavior** — `ask` (teams, default), `fix` (solo), `defer` (only `on_fail`); `on_fail`/`on_warn` set independently.
2. **Artifact/prompt language** — e.g. `pt-BR`, `en`, `es`; see ${CLAUDE_SKILL_DIR}/patterns/language.md.
3. **Pipeline phases** — default all enabled (dev, test, perf, security, review, homolog, pr); name any to disable.
4. **Test Scope** — show detected type + computed defaults; reply with overrides or Enter to confirm.
5. **Scenario Depth** — `full` (default: nominal+edge+error/AC), `light` (nominal+dominant error/AC), `none`.
6. **Clarify step** — `on` (default, up to 5 ranked questions before spec) or `off`.

Write the answers into the matching config fields above.

### 6. Present and confirm

Show the generated config, ask "Is the configuration correct? Would you like to adjust anything?", apply adjustments. After approval: "Ship initialized successfully. You can now use `/ship:run <issue or description>` to start the full pipeline."

---

## Rules

- Never fabricate — mark undetected fields "not detected", let the user fill them in
- Prioritize filesystem evidence over assumptions
- Empty project: create a minimal config, note it updates as code is created
- Always parallelize exploration via the Agent tool — never run analyses sequentially
