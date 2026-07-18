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

---

> **Path resolution safety.** `${CLAUDE_SKILL_DIR}/...` paths resolve via the harness. On failure, do NOT search the filesystem — log `⚠ ${CLAUDE_SKILL_DIR} did not resolve — skipping <path>` and skip that step only.

## Prerequisites

1. `ship/config.md` must exist — else tell the user to run `/ship:init` and STOP.
2. Storage mode: ${CLAUDE_SKILL_DIR}/patterns/storage-mode.md.
3. Linear needs an issue ID; Local needs `ship/changes/` feature folders (else run `/ship:spec`).

## Detect input mode

Parse `$ARGUMENTS`: a Linear ID or local `TASK-001` → single task (default). `--project`/`--milestone`/multiple IDs → multi-task. **Default: 1 at a time** — ask to continue after each.

---

## Pipeline Execution (per task)

### 0.4–0.7. Initialize the run context

> See ${CLAUDE_SKILL_DIR}/patterns/run-context.md for canonical files/lifecycle, ${CLAUDE_SKILL_DIR}/patterns/diff-classifier.md for classification.

One call does resume-check, scratch-dir init, snapshots, baseline diff+class. `<task-id>` matches `[a-zA-Z0-9_-]` only.

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" init <task-id>
```

- **Exit 0** (fresh): creates `stack.md`, provisional `diff.md`, `phase-status.md`/`dispatch-log.md` headers, snapshots, `diff-class.txt`. Log: `Run context: .context/ship-run/<task-id>/ (stack + diff cached)` and `Diff class (baseline): <diff_class>`.
- **Exit 3** (resume — prior run found, `RESUME` report with dispatch/completion state): report it, ask **resume** (`--mode resume` — preserves logs, re-captures diff/class, jumps past the last completed phase) or **restart** (`--mode fresh`).
- **Exit 1** (error): surface stderr, stop.

### 1. Load task context

**Linear:** `get_issue`, `get_project`, `list_documents`+`get_document` (Proposal/Design). **Local:** ${CLAUDE_SKILL_DIR}/patterns/load-artifacts.md.

Both modes:
1. Read `ship/config.md` (${CLAUDE_SKILL_DIR}/patterns/stack-detection.md).
2. Build the **effective phase set**: `Pipeline Profile → profile` (default `standard`) sets defaults per ${CLAUDE_SKILL_DIR}/patterns/profiles.md (unrecognized → `standard` + warn); explicit `Pipeline Phases` entries override. Log: `Profile: <name> → fases ativas: <list> | puladas por profile: <list>`, with `| override: <phase>: <state>` per override.
3. Extract `Artifact language` as `artifact_language` — inject into every phase dispatch below (phases don't reload ${CLAUDE_SKILL_DIR}/patterns/language.md).
4. Log `Scenario Depth: <depth>` (default `full`), visibility-only.
5. **Dispatch logging** — immediately before invoking any phase tool (steps 2–4):
   ```bash
   bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" dispatch .context/ship-run/<task-id> <phase> <Skill|Agent> <name> <model>
   ```
   `<phase>` ∈ {`plan`,`dev`,`test`,`perf`,`security`,`review`,`analyze`}; `<tool>` = `Agent` for `subagent_type` dispatches, `Skill` for forked skills; `<name>` = subagent/skill name; `<model>` from its frontmatter. Re-runs call again (always appends). Skipped: `tool=-`, `name=skipped`, `model=-`.

> **MANDATORY — Linear: move the issue to its started state now.** Resolve the name per ${CLAUDE_SKILL_DIR}/patterns/linear-status.md (never hardcode `"In Progress"`), then `save_issue` with `state: <target-state>`. Confirm before continuing.

**Persist spec + design to scratch (once):** write `spec.md` + `design.md` (full, unsliced) — `plan`/`develop`/`analyze` read these instead of re-inlining. `spec.md`: (1) this task's full description; (2) full text of only the requirement sections its AC belong to; (3) a scope index for the rest — `<req-id> — <title> — covered by <issue-id>` per line (em-dash, never a heading, so analyze ignores it). Local mode slices `proposal.md` the same way.

### 1.9. PHASE: Plan (Test-Aware Planning)

> Runs when `dev` is enabled AND warranted.

**Skip the planner** when the issue predicts a single module: (a) has `## Files`; (b) ≤3 code files there (filter per ${CLAUDE_SKILL_DIR}/patterns/diff-classifier.md, excluding `plugins/**` rebuild lines); (c) Notes say `Dependencies: None`; (d) all Scenarios share one test-layer tag. All four hold → skip, log `Planner pulado (issue prevê módulo único: N arquivo(s))`, dispatch-log a skipped row, go straight to `ship:develop` (single-module fallback).

Otherwise use the **baseline** class from step 0: empty (greenfield) or `normal`/`large` → **run the planner**; `trivial`/`minor` on existing work → **skip** (log `Diff <class> (baseline) — planner pulado`).

You are the orchestrator, not the planner — trust `plan.md`.

Invoke `ship:plan` via **Skill tool** (`context: fork` + `model: sonnet` — never `Agent`). Inline: task/title, `Artifact language`, scratch dir, storage mode, pointer to read `spec.md`/`design.md` from scratch.

**Plan validation (deterministic, only if `plan.md` exists):**
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/plan-validate.sh" .context/ship-run/<task-id>/plan.md
```
Exit 0 → log `Plan validado ✓`, proceed. Exit 2 → do NOT dispatch develop/test; surface stderr, re-run `ship:plan` with that error or ask the user.

### 2. PHASE: Development

> Skip entirely if `dev` disabled (the verification stage's test-exec branch runs unaffected).

**Overlap** (dispatch `ship:develop` + `ship:test Mode: generate` in the SAME turn, both forked skills — never `Agent`) applies only when `dev`+`test` enabled AND `plan.md` exists (its denylist keeps file sets disjoint). Log both via `pipeline.sh dispatch` (`dev`, and `test` as `ship:test (generate)`) first.

`ship:develop` — inline: task/title, `Artifact language`, scratch dir, storage mode, pointer to `spec.md`/`design.md`. Reads `plan.md` for the module map; without one, single-module (overlap already false).

`ship:test Mode: generate` (only under overlap) — same inline shape + `Mode: generate`, "use AC to guide generation, scoped to this task, don't run yet." Reads `plan.md`'s Test Contract, derives its own denylist, writes test files + `generated-tests.md` — no `test-failures.md`.

**Consolidate phase-status (MANDATORY, before proceeding)** — each dispatched agent wrote its own `phase-status-<phase>.md` scratch row (see ${CLAUDE_SKILL_DIR}/patterns/run-context.md → "Read/write conventions"); you are the sole writer of `phase-status.md`:
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" complete .context/ship-run/<task-id> 1 dev test
```
(current re-run number instead of `1`; drop `test` if the overlap didn't run.)

**Line-count check:** `git diff --stat` after develop — warn past 400 lines, don't block.

### 2.5. Refresh diff + classification (authoritative)

> Only if `dev` ran — develop writes to the tree without committing, so the baseline diff misses it. Authoritative input for the verification stage and Phase 5.

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/capture-diff.sh" .context/ship-run/<task-id>/diff.md
bash "${CLAUDE_SKILL_DIR}/hooks/diff-classify.sh" .context/ship-run/<task-id>/diff.md .context/ship-run/<task-id>/diff-class.txt
```
Log `Diff reclassificado pós-develop: <class> (<reason>)`.

### 2.6. Develop evidence gate (MANDATORY)

> Only if `dev` ran. Trust the script's verified mutation, not develop's self-report.

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/post-develop-files.txt
bash "${CLAUDE_SKILL_DIR}/hooks/snapshot-files.sh" diff .context/ship-run/<task-id>/pre-develop-files.txt \
         .context/ship-run/<task-id>/post-develop-files.txt
```

- **Non-empty** (files changed): log `Develop evidence: <N> arquivo(s) modificado(s) ✓`, continue.
- **Empty**, baseline `diff.md` non-empty (pre-existing work): legitimate re-run — row gate=`warn`, notes=`develop sem mudanças — implementação pré-existente assumida`, warn, continue.
- **Empty**, baseline also empty (silent failure — no worker dispatched): **STOP.** Row gate=`fail`, notes=`develop não produziu código — orquestrador não despachou workers`. Report; do not proceed to testing/quality.

**Untested-files report (non-blocking, only when Non-empty):**
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/evidence-gate.sh" .context/ship-run/<task-id>/develop-touched-files.txt
```
Log its `untested` JSON list. `test` enabled AND `untested` non-empty → append `warn` row — never `fail`.

### 3-4. STAGE: Verification (test-exec ∥ quality)

`test` enabled, no `generated-tests.md` yet → dispatch `ship:test Mode: generate` (no denylist).

> Same turn: (a) `test-exec.sh`, (b) quality fan-out — neither waits. `test` disabled → skip (a); quality disabled → skip (b).

**(a) Test execution:**
```bash
timeout 300 bash "${CLAUDE_SKILL_DIR}/hooks/test-exec.sh" .context/ship-run/<task-id> [--config <config-path>]
```
- **0** green → pass, continue, zero agents.
- **1** red → ONE fix **Agent** (`model: sonnet`, `test-failures.md`); `$TEST_FIX_ITERATION` (≠ `$FIX_ITERATION`); re-run after fix; `>2` → **STOP** ("Suíte vermelha. Intervenção manual necessária.").
- **2** unresolved → warn; write `phase-status-test.md` gate=`skip`; offer `Mode: execute`, never auto-invoke.
- **124** timeout → **STOP**.

**Reconciliation** (fix touched source, suite green): snapshot files (`snapshot-files.sh`, as below) → `bash "${CLAUDE_SKILL_DIR}/hooks/rerun-scope.sh" <changed-files> <drift-findings.json>` → re-dispatch quality phases marked `rerun`.

**(b)** — `perf`/`security`/`review`/`analyze` per the effective set.

Pre-quality snapshot already captured (`pre-quality-snapshot.sha`, step 0).

```bash
DIFF_CLASS=$(cat .context/ship-run/<task-id>/diff-class.txt)
```
Apply ${CLAUDE_SKILL_DIR}/patterns/diff-classifier.md → "Behavior per Class" on top of the effective set: **`trivial`** → all four skipped (still log the `analyze` PASS row), go to Phase 5; **`minor`** → only 1 combined security agent runs, `analyze` still runs; **`normal`/`large`** → no adjustment.

Dispatch all enabled phases in a SINGLE turn (concurrent); `pipeline.sh dispatch` before each. All read `diff.md` themselves (never `git diff`); scratch dir + `Artifact language` on every dispatch:
- **`perf`**: **Agent tool**, `subagent_type: ship:ship-perf`. + task, storage mode, project type, stack, `Severity Overrides`.
- **`security`**: **Agent tool**, `subagent_type: ship:ship-security`. Same + `Security Focus`.
- **`review`**: **Skill tool**. + "analyze this task's diff only, write findings to `review-findings.md`" (scratch dir only — never `ship/changes/` in Linear mode).
- **`analyze`** (per diff-class adjustment above): **Skill tool**, never `Agent`. + read `spec.md`/`design.md`/`diff.md` from scratch; run the deterministic correlation engine (no sub-agents); compute its own severities (aggregated gate is `pipeline.sh gate`, Phase 5); scope-index entries ignored by format; monorepo → restrict to diff-detected workspaces; persist output once Phase 5's decision is known (Linear: `save_comment` + `drift-findings.json`; Local: `drift-report.md`).

### 5. GATE CHECK

**Consolidate phase-status (MANDATORY, before evaluating the gate)** — each quality agent wrote its own `phase-status-<phase>.md`; you are the sole writer of `phase-status.md`:
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/status-consolidate.sh" 1 <scratch-file>...
```
(pass each enabled phase's `phase-status-<phase>.md`, and the current run number instead of `1`), append its stdout to `phase-status.md`.

**Evaluate the gate** — reads `phase-status.md`, applies `Severity Overrides` + `Gate Behavior → on_fail/on_warn` from `ship/config.md` itself:
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" gate .context/ship-run/<task-id>
```
Parse `decision`/`action` from stdout (exit mirrors decision). Fires once against the aggregated decision.

- **`FAIL`**: present findings; create tracking (Linear: sub-issues via `save_issue`; Local: `tracking.md`); act on `action` — `ask` (offer fix), `fix` (snapshot pre-fix, fix Agent with `model: sonnet`, then Surgical Re-run), `defer` (proceed).
- **`WARN`**: present warnings; act on `action` — `ask` (offer fix/proceed), `fix` (same as FAIL), `pass` (proceed).
- **`PASS`**: continue automatically.

#### Surgical Re-run Procedure

> Track `$FIX_ITERATION` (start 1); `> 3` → abort ("Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."). Read ${CLAUDE_SKILL_DIR}/patterns/gates.md first for rationale/edge cases.

**Pre-fix snapshot** (immediately before the fix Agent): `bash "${CLAUDE_SKILL_DIR}/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/pre-fix-files.txt`.

After the fix agent returns:
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/post-fix-files.txt
bash "${CLAUDE_SKILL_DIR}/hooks/snapshot-files.sh" diff .context/ship-run/<task-id>/pre-fix-files.txt \
         .context/ship-run/<task-id>/post-fix-files.txt
```
Empty result → ${CLAUDE_SKILL_DIR}/patterns/gates.md Edge case 1: log `⚠ Fix não produziu mudanças. Re-run ignorado.`, `warn` rows (`fix sem mudanças — revisão manual necessária`), skip to acceptance.

Read `on_fail_rerun` (`ship/config.md → Gate Behavior`, default `surgical`). `all` → re-run every originally-enabled phase. `surgical` (default):
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/rerun-scope.sh" .context/ship-run/<task-id>/post-fix-changed-files.txt \
     .context/ship-run/<task-id>/drift-findings.json
```
JSON: `out_of_scope: true` → gates.md Edge case 4 (re-run all enabled phases, log `Fix tocou arquivo(s) fora do scope original`); `empty: true` → confirms the empty case; else read `phases.<phase>.rerun`/`.reason` per phase, logging gates.md's `Fix tocou:`/`Re-run cirúrgico:`/`Re-run pulado:` format.

**Re-invoke only the selected phases** (same pattern as the verification stage's quality fan-out, parallel if multiple; `analyze` follows gates.md's broad-scope rule unless `analyze.rerun=false`). Each writes its `phase-status-<phase>.md`; after all return, consolidate again:
```bash
bash "${CLAUDE_SKILL_DIR}/hooks/status-consolidate.sh" <N> <scratch-file>...
```
append its stdout to `phase-status.md` and add `notes=re-run cirúrgico`.

**After re-run:** `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" gate .context/ship-run/<task-id>` again, same `decision`/`action` handling, incrementing `$FIX_ITERATION`.

### 6. PHASE: User Acceptance

> Skip if `homolog` disabled.

Invoke `ship:homolog` via **Skill tool** — NOT forked, runs in this same context, never `Agent`. Inline: consolidate findings into a quality report, present it, wait for approval, `Artifact language`.

> **MANDATORY STOP** if homolog asks a question — stop, don't continue to Phase 7 or mark complete. Proceed only on explicit approval; on requested adjustments, apply and re-invoke `ship:homolog`.

### 7. MANDATORY STOP — await user confirmation for PR

1. **Verify Linear lifecycle** (safety-net): resolve the completed-state per ${CLAUDE_SKILL_DIR}/patterns/linear-status.md (never hardcode `"Done"`); confirm `state.type == "completed"` (fix via `save_issue`) and the quality-report comment exists (`save_comment`) — never `get_issue_status`. **Local:** write `report-<task-id>.md`, mark `done` in `tasks.md`. **Both:** clean up temp files.
2. Inform the user — multi-task: ask to continue or stop; single task: "**Task complete!** Run `/ship:pr` when ready."
3. **STOP** — never invoke `/ship:pr` automatically.

---

## Multi-task mode

Sort by Linear milestone order, then issue creation date (never infer dependencies — pass explicit IDs to force order). One task at a time, asking before continuing; summarize at the end. **Never parallel** — tasks modify code.

## Orchestrator Rules

- 1 task at a time unless requested otherwise.
- Quality checks always run in parallel; never `run_in_background: true` or backgrounded Bash (${CLAUDE_SKILL_DIR}/patterns/parallelism.md) — "parallel" means synchronous calls in the same turn, always awaited.
- FAIL gates are non-negotiable; disabled phases get a one-line skip notice.
- Inject `artifact_language` into every phase prompt; don't reload ${CLAUDE_SKILL_DIR}/patterns/language.md.
- Shared scratch dir: ${CLAUDE_SKILL_DIR}/patterns/run-context.md. Linear = zero local artifacts; Local = full `ship/changes/` workspace.
- Never create the PR automatically — the user runs `/ship:pr`.
