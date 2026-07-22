---
name: ship:run
description: "Full development pipeline for a task: develop → verify (test ∥ quality, one gate) → homolog. 1 task by default, or N / whole project on request."
argument-hint: "<task-id | linear-issue-id | --project project-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Run — Pipeline Driver

The pipeline's phase ordering, scoping, gating, fix loops and re-runs live in one deterministic state machine: `pipeline.sh next`. You are its executor — call it, do exactly what it prints, call it again. You never decide what runs next.

**Input received:** $ARGUMENTS

> **STRICT RULE:** never run `ship:audit:*` from this pipeline — audits are project-wide, user-triggered separately; `ship:run` is diff-scoped only.

> `${CLAUDE_SKILL_DIR}/...` failure: log, skip — never search the filesystem.

## Prerequisites

`ship/config.md` must exist (else `/ship:init` + STOP); storage mode @@ship/patterns/storage-mode.md; Linear needs an issue ID, Local needs `ship/changes/` folders (else `/ship:spec`).

## Detect input mode

Linear ID or local `TASK-001` → single task (default). `--project`/`--milestone`/multiple IDs → multi-task: sort by milestone order, issue date (never infer dependencies; explicit IDs force order), run the loop below once per task sequentially (tasks modify code), ask to continue after each, summarize at end. `<task-id>` matches `[a-zA-Z0-9_-]` only.

## The loop (per task)

1. Run with a generous timeout (the test suite executes inside it):
   `bash "@@ship/hooks/pipeline.sh" next <task-id>`
   Add `--mode fresh` only when the user explicitly asks to discard a previous run; add `--answer <token>` only when the previous instruction told you which token to send.
2. Parse `state=`, `action=`, `run=`, `log=`, `instruction:` and act on the action:
   - `dispatch` → make EVERY listed tool call now, all in this same turn, synchronous, never backgrounded. Skill lines: invoke via the Skill tool exactly as written (forked skills fork themselves — never wrap in Agent). Agent lines: use the exact `subagent_type`, model and prompt given.
   - `work` → do the described work yourself, in this context.
   - `ask` → relay the question to the user in the artifact language, STOP; when they answer, re-run step 1 with the matching `--answer`.
   - `stop` → report the stated reason to the user and STOP.
   - `done` → follow the closing instruction, report, STOP.
3. When every call from step 2 has returned, go to step 1. Non-zero exit: surface stderr to the user and STOP.

## Rules

- Never invoke a phase tool the instruction didn't list; never skip one it did; never reorder or re-evaluate — the state machine already did.
- FAIL gates are non-negotiable; only `pipeline.sh next` resolves gate outcomes.
- Never auto-create the PR — the user runs `/ship:pr`.
- Language: user-facing output in the config's `Artifact language`; code, commits, branch names stay English (@@ship/patterns/language.md).
- Bundled references the instructions point at: @@ship/patterns/run-context.md, @@ship/patterns/linear-status.md, @@ship/patterns/load-artifacts.md, @@ship/patterns/lazy-load-findings.md, @@ship/patterns/diff-classifier.md, @@ship/patterns/gates.md.
