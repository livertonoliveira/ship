---
name: ship:run
description: "Full development pipeline for a task: develop → verify (test ∥ quality, one gate) → homolog. 1 task by default, or N / whole project on request."
argument-hint: "<task-id | linear-issue-id | --project project-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Run — Development Pipeline

Drive a task through implementation → verification → user acceptance. Phases run sequentially; only test-layer and quality fan-outs are parallel.

**Linear:** everything lives in Linear. **Local:** everything lives in `ship/changes/<feature>/`.

**Input received:** $ARGUMENTS

> **STRICT RULE:** never run `ship:audit:*` from this pipeline — audits are project-wide, user-triggered separately; `ship:run` is diff-scoped only.

> `${CLAUDE_SKILL_DIR}/...` failure: log, skip — never search the filesystem.

## Prerequisites

`ship/config.md` must exist (else `/ship:init` + STOP); storage mode ${CLAUDE_SKILL_DIR}/patterns/storage-mode.md; Linear needs an issue ID, Local needs `ship/changes/` folders (else `/ship:spec`).

## Detect input mode

Linear ID or local `TASK-001` → single task (default). `--project`/`--milestone`/multiple IDs → multi-task: sort by milestone order, issue date (never infer dependencies; explicit IDs force order), sequential (tasks modify code), ask to continue after each, summarize at end.

---

## Pipeline Execution (per task)

### 0.4–0.7. Initialize the run context

> ${CLAUDE_SKILL_DIR}/patterns/run-context.md, ${CLAUDE_SKILL_DIR}/patterns/diff-classifier.md.

`bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" init <task-id>` — resume-check, scratch-dir init, snapshots (incl. `pre-develop-files.txt`), baseline diff+class; `<task-id>` matches `[a-zA-Z0-9_-]` only. Exit 0 fresh; Exit 3 report `RESUME`, ask `--mode resume`/`fresh`; Exit 1 surface stderr, stop.

### 1. Load task context

Linear: `get_issue`/`get_project`/`list_documents`+`get_document`. Local: ${CLAUDE_SKILL_DIR}/patterns/load-artifacts.md.

Read `ship/config.md` (${CLAUDE_SKILL_DIR}/patterns/stack-detection.md); effective phase set = profile default (${CLAUDE_SKILL_DIR}/patterns/profiles.md) + `Pipeline Phases` overrides. Extract `Artifact language` for every dispatch below.

Before invoking ANY phase tool below — plan/dev/test/perf/security/review/analyze, no exceptions: `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" dispatch .context/ship-run/<task-id> <phase> <Skill|Agent> <name> <model>` (skipped → `-`/`skipped`/`-`; re-runs append again).

> Linear MANDATORY: move issue to started state (${CLAUDE_SKILL_DIR}/patterns/linear-status.md, never hardcode) — automatically, no confirmation.

Persist `spec.md`+`design.md` to scratch once (${CLAUDE_SKILL_DIR}/patterns/run-context.md, which defines the `spec.md` slice + scope-index format) — phases read these, not re-inlined.

### 1.9. PHASE: Plan

> Runs only if `dev` enabled and warranted.

Skip when the issue predicts one module (`## Files` ≤3 code files per ${CLAUDE_SKILL_DIR}/patterns/diff-classifier.md excl. `plugins/**` rebuild lines, `Dependencies: None`, one test-layer tag) → log skip, `ship:develop`. Else: greenfield/`normal`/`large` baseline runs planner, `trivial`/`minor` on existing work skips.

Invoke `ship:plan` via Skill (`context: fork`, `model: sonnet`, never Agent) — inline task/title, language, scratch dir, storage mode, spec/design pointer. Validate: `bash "${CLAUDE_SKILL_DIR}/hooks/plan-validate.sh" .context/ship-run/<task-id>/plan.md`. Exit 0 proceed; Exit 2 → skip develop/test, re-plan or ask user.

### 2. PHASE: Development

> Skip if `dev` disabled (Verification's test-exec still runs).

Log `pipeline.sh dispatch` for `dev` first, then invoke `ship:develop` via Skill (`context: fork`, never Agent), alone — no other phase runs this turn. Inline: task/title, language, scratch dir, storage mode, spec/design pointer — it reads `plan.md`'s module map (else single-module) and implements every module itself, sequentially.

Consolidate phase-status (MANDATORY, before proceeding) — sole writer of `phase-status.md`: `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" complete .context/ship-run/<task-id> <N> dev`. Line-count: `git diff --stat`, warn past 400.

### 2.5. Post-develop consolidation (MANDATORY if `dev` ran)

> develop writes to the tree without committing — one call refreshes `diff.md` + class, verifies the mutation against the pre-develop snapshot (trusted over develop's self-report), and counts untested touched files.

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" post-develop .context/ship-run/<task-id>
```
Parse `evidence`: `ok` → ✓ continue. `warn` (re-run, no new mutation) → note, continue. `fail` (nothing written) → **STOP**. `untested` >0 → `warn`, non-blocking, never `fail`. `diff_class` is refreshed in `diff-class.txt` for the quality scope.

### 3-4. STAGE: Verification (quality ∥ test-gen, then test-exec ∥ analyze)

Quality scope once (deterministic): `bash "${CLAUDE_SKILL_DIR}/hooks/quality-scope.sh" <class> --phases "perf security review analyze" --scratch .context/ship-run/<task-id>` (`<class>` from `diff-class.txt`): writes PASS skip rows, prints `run=`/`depth=`/`log=`. Pre-quality snapshot captured (step 0).

**Turn A — dispatch concurrently, nothing waits** (all read `diff.md`/`plan.md`; `pipeline.sh dispatch` before each): `ship:test Mode: generate` (its test-layer fan-out is parallel internally; skip if `generated-tests.md` exists — re-run) **plus** the `run=` phases among `perf`/`security`/`review`. `test` disabled → drop test-gen; empty `run=` → drop those.

**Turn B — after A** (both need the generated tests): (a) test-exec ∥ (b) `analyze` if in `run=`.

**(a) Test execution:**
```bash
timeout 300 bash "${CLAUDE_SKILL_DIR}/hooks/test-exec.sh" .context/ship-run/<task-id> [--config <config-path>]
```
Exit 0 green → pass, zero agents. Exit 1 red → `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" iter .context/ship-run/<task-id> test-fix --max 2`; limit hit → **STOP** ("Suíte vermelha. Intervenção manual necessária."); else ONE fix Agent (`model: sonnet`, `test-failures.md`), re-run. Exit 2 unresolved → warn, `phase-status-test.md` gate=`skip`, offer `Mode: execute`, never auto-invoke. Exit 124 timeout → **STOP**.

Reconciliation (fix touched source, suite went green): snapshot (as 2.5) → `bash "${CLAUDE_SKILL_DIR}/hooks/rerun-scope.sh" <changed-files> <drift-findings.json> --config ship/config.md` → re-dispatch phases marked `rerun`.

**Common inline** (every quality Agent — `ship:ship-perf`/`-security`/`-review`/`-analyze` direct, never Skill wrappers): task, language, storage mode, scratch, `Severity Overrides`, `Fan-out: <depth>` (perf/security/review — flat = no sub-agents), `Findings gate script:` `${CLAUDE_SKILL_DIR}/hooks/findings-gate.sh`; each reads `diff.md` from scratch, never recomputes.
- `perf`/`review` + project/stack. `review` writes `review-findings.md` (scratch only, never `ship/changes/` in Linear).
- `security` + `Security Focus`, `Diff slice script:` `${CLAUDE_SKILL_DIR}/hooks/diff-slice.sh`.
- `analyze` (in `run=`): run `bash "${CLAUDE_SKILL_DIR}/hooks/analyze-precheck.sh" <spec.md> <diff.md> --scratch <dir> --test-scope <...> --findings-gate ${CLAUDE_SKILL_DIR}/hooks/findings-gate.sh` first — `agent=skip` (clean correlation, PASS row written) → dispatch `skipped`, no Agent; `agent=run` → dispatch the Agent (`Test Scope`, `Correlate script:` `${CLAUDE_SKILL_DIR}/hooks/analyze-correlate.sh`; own severities feed the gate; persists via Linear `save_comment`).

### 5. GATE CHECK

Consolidate phase-status (MANDATORY, before evaluating the gate): `bash "${CLAUDE_SKILL_DIR}/hooks/status-consolidate.sh" <N> <scratch-file>...`, append stdout to `phase-status.md`.

Evaluate: `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" gate .context/ship-run/<task-id>`. Parse `decision`/`action`; fires once. Decision rule (critical/high→FAIL, medium→WARN, low/none→PASS): ${CLAUDE_SKILL_DIR}/patterns/gates.md.

FAIL: present findings, tracking (Linear sub-issues / local `tracking.md`); `ask` offer fix / `fix` snapshot+fix Agent+Surgical Re-run / `defer` proceed. WARN: same, `pass` replaces `defer`. PASS: continue.

#### Surgical Re-run Procedure

> `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" iter .context/ship-run/<task-id> fix --max 3`; limit hit → abort ("Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."). Edge cases: ${CLAUDE_SKILL_DIR}/patterns/gates.md.

Pre-fix snapshot (before the fix Agent): `bash "${CLAUDE_SKILL_DIR}/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/pre-fix-files.txt`. After: same `snapshot`+`diff` pattern as 2.6 against `pre-fix-files.txt`/`post-fix-files.txt`. Empty diff → gates.md Edge case 1 (`warn` rows, skip to acceptance).

`bash "${CLAUDE_SKILL_DIR}/hooks/rerun-scope.sh" <changed-files> <drift-findings.json> --config ship/config.md` reads `on_fail_rerun` itself: `all` forces every `rerun=true`; default `surgical` — `out_of_scope` → re-run all (Edge case 4), else per-phase `rerun` selects.

Re-invoke selected phases (same pattern as (b)); each writes its `phase-status-<phase>.md`, then consolidate again: `bash "${CLAUDE_SKILL_DIR}/hooks/status-consolidate.sh" <N> <scratch-file>...`, append stdout, add `notes=re-run cirúrgico`. Re-run `pipeline.sh gate`; another fix repeats the `iter` gate above.

### 6. PHASE: User Acceptance

> Skip if `homolog` disabled.

Invoke `ship:homolog` via Skill — not forked, same context, never Agent. Inline: consolidate findings, present, await approval, language.

> MANDATORY STOP if homolog asks a question. Proceed only on approval; on adjustments, apply and re-invoke.

### 7. MANDATORY STOP — await user confirmation for PR

Verify Linear lifecycle: resolve completed-state (${CLAUDE_SKILL_DIR}/patterns/linear-status.md, never hardcode), confirm `state.type == "completed"` + quality-report comment exist. Local: write `report-<task-id>.md`, mark `done` in `tasks.md`. Both: surface the per-phase wall-clock (`bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" report-timings .context/ship-run/<task-id>`), then clean up temp files.

Inform user — multi-task: ask to continue/stop; single: "**Task complete!** Run `/ship:pr` when ready." STOP — never auto-invoke `/ship:pr`.

---

## Orchestrator Rules

- 1 task at a time unless requested; quality checks always parallel — synchronous, same turn, never backgrounded (${CLAUDE_SKILL_DIR}/patterns/parallelism.md); FAIL gates non-negotiable.
- Shared scratch dir: ${CLAUDE_SKILL_DIR}/patterns/run-context.md (Linear = zero local artifacts; Local = full `ship/changes/`).
- Never auto-create the PR — the user runs `/ship:pr`.
