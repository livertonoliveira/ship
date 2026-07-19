---
name: ship:run
description: "Full development pipeline for a task: develop → verify (test ∥ quality, one gate) → homolog. 1 task by default, or N / whole project on request."
argument-hint: "<task-id | linear-issue-id | --project project-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Run — Development Pipeline

Drive a task through implementation → verification → user acceptance, maximizing parallel agents.

**Linear:** everything lives in Linear. **Local:** everything lives in `ship/changes/<feature>/`.

**Input received:** $ARGUMENTS

> **STRICT RULE:** never run `ship:audit:*` from this pipeline — audits are project-wide, user-triggered separately; `ship:run` is diff-scoped only.

> `${CLAUDE_SKILL_DIR}/...` failure: log, skip — never search the filesystem.

## Prerequisites

`ship/config.md` must exist (else `/ship:init` + STOP); storage mode @@ship/patterns/storage-mode.md; Linear needs an issue ID, Local needs `ship/changes/` folders (else `/ship:spec`).

## Detect input mode

Linear ID or local `TASK-001` → single task (default). `--project`/`--milestone`/multiple IDs → multi-task: sort by milestone order, issue date (never infer dependencies; explicit IDs force order), sequential (tasks modify code), ask to continue after each, summarize at end.

---

## Pipeline Execution (per task)

### 0.4–0.7. Initialize the run context

> @@ship/patterns/run-context.md, @@ship/patterns/diff-classifier.md.

`bash "@@ship/hooks/pipeline.sh" init <task-id>` — resume-check, scratch-dir init, snapshots (incl. `pre-develop-files.txt`), baseline diff+class; `<task-id>` matches `[a-zA-Z0-9_-]` only. Exit 0 fresh; Exit 3 report `RESUME`, ask `--mode resume`/`fresh`; Exit 1 surface stderr, stop.

### 1. Load task context

Linear: `get_issue`/`get_project`/`list_documents`+`get_document`. Local: @@ship/patterns/load-artifacts.md.

Read `ship/config.md` (@@ship/patterns/stack-detection.md); effective phase set = profile default (@@ship/patterns/profiles.md) + `Pipeline Phases` overrides. Extract `Artifact language` for every dispatch below.

Before invoking ANY phase tool below — plan/dev/test/perf/security/review/analyze, no exceptions: `bash "@@ship/hooks/pipeline.sh" dispatch .context/ship-run/<task-id> <phase> <Skill|Agent> <name> <model>` (skipped → `-`/`skipped`/`-`; re-runs append again).

> Linear MANDATORY: move issue to started state (@@ship/patterns/linear-status.md, never hardcode) — automatically, no confirmation.

Persist `spec.md`+`design.md` to scratch once (@@ship/patterns/run-context.md) — phases read these, not re-inlined. `spec.md`: task description + only the requirement sections its ACs belong to + a scope index for the rest (`<req-id> — <title> — covered by <issue-id>`, em-dash, never a heading, so analyze ignores it).

### 1.9. PHASE: Plan

> Runs only if `dev` enabled and warranted.

Skip when the issue predicts one module (`## Files` ≤3 code files per @@ship/patterns/diff-classifier.md excl. `plugins/**` rebuild lines, `Dependencies: None`, one test-layer tag) → log, straight to `ship:develop`. Else: greenfield/`normal`/`large` baseline runs planner, `trivial`/`minor` on existing work skips.

Invoke `ship:plan` via Skill (`context: fork`, `model: sonnet`, never Agent) — inline task/title, language, scratch dir, storage mode, spec/design pointer. Validate: `bash "@@ship/hooks/plan-validate.sh" .context/ship-run/<task-id>/plan.md`. Exit 0 proceed; Exit 2 → skip develop/test, re-plan or ask user.

### 2. PHASE: Development

> Skip if `dev` disabled (Verification's test-exec still runs).

Overlap: `ship:develop` + `ship:test Mode: generate` same turn (forked Skills) when `dev`+`test` enabled and `plan.md` exists, or planner skipped (§1.9) with populated `## Files` (disjoint either way). Log both via `pipeline.sh dispatch` first.

`ship:develop`: task/title, language, scratch dir, storage mode, spec/design pointer — reads `plan.md` module map, else single-module. `ship:test Mode: generate` (overlap only): `Mode: generate`, writes tests + `generated-tests.md`; denylist `plan.md` else `## Files`.

Consolidate phase-status (MANDATORY, before proceeding) — sole writer of `phase-status.md`: `bash "@@ship/hooks/pipeline.sh" complete .context/ship-run/<task-id> <N> dev test` (drop `test` if the overlap didn't run). Line-count: `git diff --stat`, warn past 400.

### 2.5. Refresh diff + classification (MANDATORY if `dev` ran)

> develop writes to the tree without committing, so the baseline diff misses it.

```bash
bash "@@ship/hooks/capture-diff.sh" .context/ship-run/<task-id>/diff.md
bash "@@ship/hooks/diff-classify.sh" .context/ship-run/<task-id>/diff.md .context/ship-run/<task-id>/diff-class.txt
```

### 2.6. Develop evidence gate (MANDATORY if `dev` ran)

Trust the script's verified mutation, not develop's self-report:
```bash
bash "@@ship/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/post-develop-files.txt
bash "@@ship/hooks/snapshot-files.sh" diff .context/ship-run/<task-id>/pre-develop-files.txt .context/ship-run/<task-id>/post-develop-files.txt
```
Non-empty → ✓. Empty + baseline non-empty (re-run) → `warn`, continue. Empty + baseline empty (no worker dispatched) → **STOP**, `fail`.

Untested-files (non-blocking): `bash "@@ship/hooks/evidence-gate.sh" .context/ship-run/<task-id>/develop-touched-files.txt`; found → `warn`, never `fail`.

### 3-4. STAGE: Verification (test-exec ∥ quality)

`test` enabled, no `generated-tests.md` yet → dispatch `ship:test Mode: generate` (no denylist) first.

Same turn: (a) test-exec, (b) quality fan-out — neither waits. `test` disabled → skip (a); quality disabled → skip (b).

**(a) Test execution:**
```bash
timeout 300 bash "@@ship/hooks/test-exec.sh" .context/ship-run/<task-id> [--config <config-path>]
```
Exit 0 green → pass, zero agents. Exit 1 red → `bash "@@ship/hooks/pipeline.sh" iter .context/ship-run/<task-id> test-fix --max 2`; limit hit → **STOP** ("Suíte vermelha. Intervenção manual necessária."); else ONE fix Agent (`model: sonnet`, `test-failures.md`), re-run. Exit 2 unresolved → warn, `phase-status-test.md` gate=`skip`, offer `Mode: execute`, never auto-invoke. Exit 124 timeout → **STOP**.

Reconciliation (fix touched source, suite went green): snapshot (as 2.6) → `bash "@@ship/hooks/rerun-scope.sh" <changed-files> <drift-findings.json>` → re-dispatch quality phases marked `rerun`.

**(b) Quality:** `perf`/`security`/`review`/`analyze` per effective set; all disabled → skip to Phase 5 (trivial PASS). Pre-quality snapshot already captured (step 0). Adjust per @@ship/patterns/diff-classifier.md: `trivial` → all skipped (still log `analyze` PASS); `minor` → one combined security agent, `analyze` still runs; `normal`/`large` → none.

Dispatch enabled phases in ONE turn, concurrent, single aggregated gate in Phase 5; `pipeline.sh dispatch` before each; scratch dir + language every dispatch; all read `diff.md`, never `git diff`.
- `perf`/`security` → Agent `ship:ship-perf`/`ship:ship-security` + task, storage mode, project/stack, `Severity Overrides` (+`Security Focus` for security).
- `review` → Skill, writes `review-findings.md` (scratch only, never `ship/changes/` in Linear).
- `analyze` → Skill, never Agent — reads `spec.md`/`design.md`/`diff.md` from scratch, own severities feed the gate; persists after.

### 5. GATE CHECK

Consolidate phase-status (MANDATORY, before evaluating the gate): `bash "@@ship/hooks/status-consolidate.sh" <N> <scratch-file>...`, append stdout to `phase-status.md`.

Evaluate: `bash "@@ship/hooks/pipeline.sh" gate .context/ship-run/<task-id>`. Parse `decision`/`action`; fires once. Decision rule (critical/high→FAIL, medium→WARN, low/none→PASS): @@ship/patterns/gates.md.

FAIL: present findings, tracking (Linear sub-issues / local `tracking.md`); `ask` offer fix / `fix` snapshot+fix Agent+Surgical Re-run / `defer` proceed. WARN: same, `pass` replaces `defer`. PASS: continue.

#### Surgical Re-run Procedure

> `bash "@@ship/hooks/pipeline.sh" iter .context/ship-run/<task-id> fix --max 3`; limit hit → abort ("Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."). Edge cases: @@ship/patterns/gates.md.

Pre-fix snapshot (before the fix Agent): `bash "@@ship/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/pre-fix-files.txt`. After: same `snapshot`+`diff` pattern as 2.6 against `pre-fix-files.txt`/`post-fix-files.txt`. Empty diff → gates.md Edge case 1 (`warn` rows, skip to acceptance).

`on_fail_rerun` default `surgical`: `all` re-runs every enabled phase; `surgical` uses `bash "@@ship/hooks/rerun-scope.sh" <changed-files> <drift-findings.json>` — `out_of_scope` → re-run all (Edge case 4), else per-phase `rerun` selects.

Re-invoke selected phases (same pattern as (b)); each writes its `phase-status-<phase>.md`, then consolidate again: `bash "@@ship/hooks/status-consolidate.sh" <N> <scratch-file>...`, append stdout, add `notes=re-run cirúrgico`. Re-run `pipeline.sh gate`; another fix repeats the `iter` gate above.

### 6. PHASE: User Acceptance

> Skip if `homolog` disabled.

Invoke `ship:homolog` via Skill — not forked, same context, never Agent. Inline: consolidate findings, present, await approval, language.

> MANDATORY STOP if homolog asks a question. Proceed only on approval; on adjustments, apply and re-invoke.

### 7. MANDATORY STOP — await user confirmation for PR

Verify Linear lifecycle: resolve completed-state (@@ship/patterns/linear-status.md, never hardcode), confirm `state.type == "completed"` + quality-report comment exist. Local: write `report-<task-id>.md`, mark `done` in `tasks.md`. Both: clean up temp files.

Inform user — multi-task: ask to continue/stop; single: "**Task complete!** Run `/ship:pr` when ready." STOP — never auto-invoke `/ship:pr`.

---

## Orchestrator Rules

- 1 task at a time unless requested; quality checks always parallel — synchronous, same turn, never backgrounded (@@ship/patterns/parallelism.md); FAIL gates non-negotiable.
- Shared scratch dir: @@ship/patterns/run-context.md (Linear = zero local artifacts; Local = full `ship/changes/`).
- Never auto-create the PR — the user runs `/ship:pr`.
