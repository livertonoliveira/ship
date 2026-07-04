---
name: ship:run
description: "Full development pipeline for a task: develop → test → perf → security → review → analyze → homolog. Works on 1 task by default, or N tasks / entire project if requested."
argument-hint: "<task-id | linear-issue-id | --project project-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Run — Development Pipeline

You are the main Ship development orchestrator. Your mission is to take a task (from Linear or local markdown) and drive it through the full development pipeline: implementation → testing → quality checks → user acceptance. You maximize the use of parallel agents at every stage.

**With Linear:** Task details, context, and quality reports all live in Linear. No local files needed.
**Without Linear:** Everything lives in `ship/changes/<feature>/` as markdown files.

**Input received:** $ARGUMENTS

---

## Prerequisites

### 1. Check initialization

Check if `ship/config.md` exists at the project root.
- If it does NOT exist: inform the user they need to run `/ship:init` first and STOP.

### 2. Determine storage mode

See @ship/patterns/storage-mode.md.

### 3. Check for specification

- **Linear mode**: The user should provide a Linear issue ID. If they don't, ask for one.
- **Local mode**: Check if `ship/changes/` contains feature folders with tasks. If none exist, inform the user to run `/ship:spec` first.

---

## Detect input mode

Analyze `$ARGUMENTS` to determine what to work on:

### Single task (default, recommended)
- **Linear issue ID** (e.g., `ABC-123`): Work on this specific task. Fetch details via `mcp__linear-server__get_issue`.
- **Local task ID** (e.g., `TASK-001`): Find the task in `ship/changes/<feature>/tasks.md`.

### Multiple tasks
- **`--project <name>`**: Work through ALL pending tasks in the specified project/feature, one at a time, in milestone order.
- **`--milestone <name>`**: Work through all pending tasks in a specific milestone.
- **Multiple IDs** (e.g., `ABC-123 ABC-124 ABC-125`): Work on these specific tasks in order.

**Default behavior**: Work on **1 task at a time**. After completing each task, ask the user: "Task complete. Continue to the next task, or stop here?"

---

## Pipeline Execution (per task)

For each task, execute the following phases:

### 0.5. Initialize shared scratch dir

> See @ship/patterns/run-context.md for canonical file formats and lifecycle rules.

After the trace is initialized, set up the shared scratch directory for this run. Use the issue ID (e.g., `MOB-1147`) as `<task-id>` — it must match `[a-zA-Z0-9_-]` only.

```bash
mkdir -p .context/ship-run/<task-id>
```

Then populate the canonical files in a single batch:

1. **`stack.md`** — Run stack-detection (see @ship/patterns/stack-detection.md): read `ship/config.md` and extract Language, Runtime, Framework, Test runner, Package manager, and any other relevant fields. Write the result in the canonical format:

   ```markdown
   # Stack

   - Language: <value>
   - Runtime: <value>
   - Framework: <value>
   - Test runner: <value>
   - Package manager: <value>
   ```

   Write this content to `.context/ship-run/<task-id>/stack.md`.

2. **`diff.md`** (provisional baseline) — Capture the branch diff **relative to the merge-base, including the working tree and untracked files**, and write the full output (no truncation) to `.context/ship-run/<task-id>/diff.md`:

   ```bash
   BASE=$(git merge-base origin/main HEAD)
   git add -A -N   # surface new untracked files in the diff without staging content; the scratch dir is gitignored so it is never added
   git diff "$BASE"
   ```

   > This is the **pre-develop baseline** — it reflects only work that already existed before this run (re-runs, pre-committed work). It is consumed solely by the planner-gate classification in step 0.7. `ship:develop` integrates code into the working tree without committing, so the **authoritative** diff that the quality phases analyze is re-captured in step 2.5, after development.

3. **`phase-status.md`** — Create the file with only the header (no rows yet):

   ```markdown
   # Phase Status

   | Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |
   |-------|-----|-----------|-------|------|----------|------|--------|-----|-------|
   ```

   Write to `.context/ship-run/<task-id>/phase-status.md`.

3b. **`dispatch-log.md`** — Create the file with only the header (no rows yet):

   ```markdown
   # Dispatch Log

   | Phase | Tool | Name | Model | Timestamp |
   |-------|------|------|-------|-----------|
   ```

   Write to `.context/ship-run/<task-id>/dispatch-log.md`. The orchestrator appends one row to this file every time it dispatches a phase (see step 8, "Phase dispatch logging convention"). `homolog` reads it to render the `## Execution Trace` section.

4. **`pre-quality-snapshot.sha`** — Capture the current HEAD SHA and write it as a single line:

   ```bash
   git rev-parse HEAD
   ```

   Write the SHA to `.context/ship-run/<task-id>/pre-quality-snapshot.sha`.

5. **`pre-develop-files.txt`** — Capture a per-file content snapshot of the working tree **before development**, so the develop evidence gate (step 2.6) can prove whether `ship:develop` actually mutated anything. `snapshot-files.sh` (via lazy-ref `@@ship/hooks/snapshot-files.sh`) is the canonical implementation of the content-snapshot mechanism reused by steps 2.6 and the Surgical Re-run Procedure, each writing to its own output file and comparing snapshots via the script's `diff` mode:

   ```bash
   bash "@@ship/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/pre-develop-files.txt
   ```

Log to the user:
```
Run context: .context/ship-run/<task-id>/ (stack + diff cached)
```

### 0.7. Diff Classification

> See @ship/patterns/diff-classifier.md for the full heuristic reference.

> **This is the baseline classification** — it runs against the pre-develop `diff.md` and feeds only the planner-gate decision in step 1.9. The **authoritative** classification that drives the Phase 4 quality gate is recomputed in step 2.5 over the post-develop diff and overwrites `diff-class.txt`.

Run the classification by invoking the script directly:

```bash
bash "@@ship/hooks/diff-classify.sh" .context/ship-run/<task-id>/diff.md .context/ship-run/<task-id>/diff-class.txt
```

- **Inputs**: `.context/ship-run/<task-id>/diff.md` (the pre-develop baseline) and `ship/config.md` (`## Sensitive Paths` overrides, read by the script from its own default path).
- **Outputs**: the script writes the class word to `.context/ship-run/<task-id>/diff-class.txt` as a direct side effect; log `Diff class (baseline): <script stdout>` (note the `(baseline)` qualifier — the script's own stdout omits it).

### 1. Load task context

**Linear mode:**
1. Use `mcp__linear-server__get_issue` to get task title, description, acceptance criteria, labels, milestone
2. Use `mcp__linear-server__get_project` to get the project context
3. Use `mcp__linear-server__list_documents` + `mcp__linear-server__get_document` to read the Proposal and Design documents linked to the project
4. Read `ship/config.md` (see @ship/patterns/stack-detection.md for stack detection logic).
5. Build the **effective phase set** for this run (applies to both Linear and Local mode):
   1. Read `Pipeline Profile → profile` from `ship/config.md` (default: `standard` if the field is absent or unknown)
   2. Look up that profile's phase defaults in `@ship/patterns/profiles.md`. If the profile name is not recognized, fall back to `standard` and warn the user.
   3. For each phase (`dev`, `test`, `perf`, `security`, `review`, `analyze`, `homolog`, `pr`): if `Pipeline Phases` has an explicit `enabled`/`disabled` entry, that override wins; otherwise use the profile default
   4. **Log to the user** before starting any phase:
      - Format: `Profile: <name> → fases ativas: <list> | puladas por profile: <list>`
      - If any explicit `Pipeline Phases` entry overrode the profile default, append: `| override: <phase>: <enabled|disabled>`
      - Example (no overrides): `Profile: lite → fases ativas: dev, pr | puladas por profile: test, perf, security, review, homolog`
      - Example (with override): `Profile: lite | override: test: enabled → fases ativas: dev, test, pr | puladas por profile: perf, security, review, homolog`

6. Extract `Artifact language` from `ship/config.md → Conventions` (e.g., `pt-BR`). Store as `artifact_language`. This value is the **orchestrator-owned language context** — inject it explicitly into every phase agent prompt you dispatch in steps 2–8: include `Artifact language: <resolved-value>` in the agent's instructions, replacing `<artifact_language>` with the actual value you resolved (e.g., write `Artifact language: pt-BR`, not the placeholder). Phase SKILL.md files will use this injected value instead of re-loading `@ship/patterns/language.md`.

7. Read `Scenario Depth → depth` from `ship/config.md` (default `full` if the section is absent). This is visibility-only — scenarios live in the spec artifacts the phases already load; the orchestrator does not thread them. Log alongside the profile/test-scope logs: `Scenario Depth: <depth>`.

8. **Phase dispatch logging convention** — every time you dispatch a phase in steps 2–5 below (Development, Testing, Quality, Analyze), emit a single line to the terminal **AND** append the same data as a row to `.context/ship-run/<task-id>/dispatch-log.md`.

   Terminal format (one line, printed immediately before invoking the tool):

   ```
   ▶ Fase: <phase> | tool=<Skill|Agent> | name=<name> | model=<haiku|sonnet>
   ```

   `dispatch-log.md` row format:

   ```
   | <phase> | <Skill|Agent> | <name> | <haiku|sonnet> | <ISO-8601 UTC> |
   ```

   Field rules:
   - `<phase>`: one of `plan`, `dev`, `test`, `perf`, `security`, `review`, `analyze`.
   - `<tool>`: `Agent` when dispatching a named agent via `subagent_type` (e.g., `ship:ship-perf`); `Skill` when dispatching a forked skill via the Skill tool (e.g., `ship:test`, `ship:review`).
   - `<name>`: the `subagent_type` value (for Agent) or the skill name with `ship:` prefix (for Skill).
   - `<model>`: read from the dispatched worker's `model:` frontmatter. Named agents in `agents/` and skills in `skills/` both declare it.
   - For re-runs (Surgical Re-run Procedure), append a new row per re-dispatched phase — do not edit existing rows.
   - For skipped phases (diff-class adjustments, disabled in effective phase set): append a row with `tool=-`, `name=skipped`, `model=-` so the trace remains complete.

   **Language convention (applies to every phase dispatch below):** include the line `Artifact language: <artifact_language>` (resolved value from step 6) in each dispatched phase's inline context. Phase SKILL.md files use this injected value for all user-facing output and do NOT re-load `@ship/patterns/language.md`. The per-phase context blocks below show this line without repeating the rationale.

> **MANDATORY — LINEAR MODE: Move issue to its started state before doing anything else**
>
> Resolve the team's **started**-state name following this recipe — **do not pass the literal `"In Progress"`**, it silently no-ops on teams whose started state has another name (e.g., `Em andamento`):
>
> Read `@@ship/patterns/linear-status.md` and follow that recipe.
>
> Then call `mcp__linear-server__save_issue` with `state: <target-state>` right now.
> Do NOT continue to the development phase until this API call is confirmed.

**Local mode:**

Follow @ship/patterns/load-artifacts.md for the Local mode artifact loading steps.

Additionally:
- Apply steps 5–6 above (effective phase set resolution and artifact_language extraction) — they are not Linear-specific.

> **From this point, all phase checks use the effective phase set built in step 5 — never raw `Pipeline Phases` alone.**

**Persist spec + design to the scratch dir (once).** Write the full task spec — issue description + ACs + `@SC-XX` scenarios + the Proposal document (REQ-XX requirements) — to `.context/ship-run/<task-id>/spec.md`, and the full Design document to `.context/ship-run/<task-id>/design.md`. The `plan`, `develop`, and `analyze` phases read these files from the scratch dir instead of having them re-inlined into every dispatch — capture them here once. In Local mode, source them from `proposal.md`/`design.md`; still write the scratch copies so every phase has a single canonical path.

### 1.9. PHASE: Plan (Test-Aware Planning)

> **Phase check**: This phase runs when `dev` is `enabled` in the **effective phase set** AND the planner is warranted. Decide from the **baseline** classification (step 0.7), which measures only work that existed *before* this run:
> - **Baseline diff is empty** (greenfield — no pre-existing committed/uncommitted work): the implementation does not exist yet, so its size is unknown and a fresh task almost always warrants decomposition → **run the planner**. Detect with `[ -s .context/ship-run/<task-id>/diff.md ] || echo greenfield`.
> - **Baseline class `normal` or `large`**: → **run the planner**.
> - **Baseline class `trivial` or `minor`** (a small change on top of work that already exists): the decomposition is obvious → **skip** the planner; `ship:develop` will treat the task as a single module. Log when skipped: `Diff <class> (baseline) — planner pulado (módulo único)`. Append a skipped row to `dispatch-log.md` (`tool=-`, `name=skipped`, `model=-`).
>
> ⚠️ Do **not** skip the planner just because the baseline class is `trivial` on a greenfield branch — an empty baseline classifies as `trivial` (zero files) but means "nothing built yet", not "trivial change". The empty-diff check above takes precedence.

The planner does ONE interpretation of the `@SC-XX` scenarios and emits `.context/ship-run/<task-id>/plan.md` — a single source of truth that BOTH develop and test consume, so code and tests drift less at the source.

> **You are the orchestrator, not the planner — do not analyze the feature yourself.** Do not deep-read the codebase or decide the implementation approach before dispatching `ship:plan`; that wastes tokens on hypotheses the planner may contradict. The spec and design are already in the scratch dir for the planner to read — just trust the returned `plan.md`. Your only pre-plan judgment is the baseline classification (step 0.7). (Rationale: `docs/design-notes/pipeline-rationale.md`.)

Invoke the `ship:plan` skill via the **Skill tool**. It declares `context: fork` + `model: "sonnet"` in its frontmatter, so the planning reasoning runs in an isolated Sonnet subagent automatically — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

```
Task: <task-id> — <title>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>

Read the spec from `.context/ship-run/<task-id>/spec.md` and the design from `.context/ship-run/<task-id>/design.md` (the orchestrator wrote them there; they are NOT injected inline).
```

**Scratch dir:** `.context/ship-run/<task-id>/`

### 2. PHASE: Development

> **Phase check**: If `dev` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 3.

Invoke the `ship:develop` skill via the **Skill tool**. It declares `context: fork` + `model: "sonnet"` in its frontmatter — an orchestrator that slices/de-identifies per-module context, fans out Sonnet `ship-develop-implement` workers, integrates, and typechecks, so do NOT wrap it in an `Agent` tool call. Pass the following context inline:

```
Task: <task-id> — <title>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>

Read the spec from `.context/ship-run/<task-id>/spec.md` and the design from `.context/ship-run/<task-id>/design.md` (the orchestrator wrote them there; they are NOT injected inline).
```

**Scratch dir:** `.context/ship-run/<task-id>/` — `ship:develop` reads `plan.md` from here for the module map. If the planner was skipped (no `plan.md`), it implements the task as a single module.

**Line count check**: After development, run `git diff --stat` to verify total lines changed. If it exceeds 400 lines:
- Warn the user: "This task produced ~X lines (target: <400). Consider splitting it."
- Do NOT block — this is a warning, not a gate.

### 2.5. Refresh diff + classification (authoritative)

> **Refresh the diff after develop.** `ship:develop` writes to the working tree without committing, so the baseline `diff.md` does not contain its output. This refreshed `diff.md` + `diff-class.txt` are the authoritative inputs for the Phase 4 gate and perf/security/review. (Rationale: `docs/design-notes/pipeline-rationale.md`.)

> **Phase check**: Run this step only if the `dev` phase actually ran (it is `enabled` in the effective phase set). If `dev` was disabled, the baseline `diff.md` already reflects the diff under analysis — skip the refresh and keep the baseline classification.

1. **Re-capture `diff.md`** over the post-develop working tree (same range and command as step 0.5, now including the new and modified source files develop wrote):

   ```bash
   BASE=$(git merge-base origin/main HEAD)
   git add -A -N   # surface develop's new untracked files in the diff without staging content
   git diff "$BASE" > .context/ship-run/<task-id>/diff.md
   ```

   **Use this exact command** — downstream consumers parse `diff.md` as a literal unified diff; `--stat`, three-dot ranges, or hand-written summaries silently misclassify (e.g. a `--stat` body reads as `0 logical files`).

   **Assert the output is a real unified diff** before continuing — fail loud rather than letting a malformed `diff.md` poison the quality gate:

   ```bash
   if [ -s .context/ship-run/<task-id>/diff.md ] \
      && ! grep -q '^diff --git ' .context/ship-run/<task-id>/diff.md; then
     echo "✗ diff.md is non-empty but has no 'diff --git' header — not a valid unified diff. Re-capture before proceeding." >&2
     exit 1
   fi
   ```

   A non-empty `diff.md` with no `diff --git` header means the capture was corrupted — re-run the command above; do not proceed to classification or quality phases on a malformed diff. (An empty `diff.md` is legitimate only when `dev` did nothing — handle that in step 2.6, not here.)

2. **Re-run the classification** by invoking the same script directly against the refreshed `diff.md`:

   ```bash
   bash "@@ship/hooks/diff-classify.sh" .context/ship-run/<task-id>/diff.md .context/ship-run/<task-id>/diff-class.txt
   ```

   This overwrites `.context/ship-run/<task-id>/diff-class.txt` with the new class as a direct side effect. This is the value Phase 4 reads via `cat .context/ship-run/<task-id>/diff-class.txt`.

3. **Log to the user**:

   ```
   Diff reclassificado pós-develop: <class> (<reason>)
   ```

### 2.6. Develop evidence gate (MANDATORY)

> **Prove develop produced code — never trust its self-report.** `ship:develop` can narrate a plan and return a success-looking status without dispatching any worker, leaving the working tree untouched. This gate verifies real mutation from the working-tree snapshots; never accept develop as `pass` on its word alone. (Rationale: `docs/design-notes/pipeline-rationale.md`.)

> **Phase check**: Run this gate only if the `dev` phase actually ran (it is `enabled` in the effective phase set). If `dev` was disabled, skip this gate entirely.

1. **Compute what develop actually changed** — run the content-snapshot idiom from step 0.5, writing to `post-develop-files.txt`, then diff it against the `pre-develop-files.txt` snapshot to list the files develop created or whose content changed this phase:

   ```bash
   bash "@@ship/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/post-develop-files.txt
   bash "@@ship/hooks/snapshot-files.sh" diff .context/ship-run/<task-id>/pre-develop-files.txt \
            .context/ship-run/<task-id>/post-develop-files.txt
   ```

2. **Decide**:

   - **Non-empty** (develop mutated ≥1 file): evidence confirmed. Log `Develop evidence: <N> arquivo(s) modificado(s) ✓` and continue to Phase 3.

   - **Empty** (develop touched nothing this phase): distinguish a silent failure from a legitimate re-run by inspecting the **pre-develop** baseline `diff.md` (step 0.5):
     - **Baseline `diff.md` was non-empty** (work already existed before this run): treat as a legitimate "already implemented" re-run. Append a develop row to `phase-status.md` with gate=`warn` and notes=`develop sem mudanças — implementação pré-existente assumida`. Warn the user: `⚠ Develop não produziu mudanças; assumindo implementação pré-existente (re-run).` Continue.
     - **Baseline `diff.md` was empty** (fresh task, nothing existed): this is the silent-failure mode — develop returned without dispatching any worker. **The pipeline STOPS.** Append a develop row to `phase-status.md` with gate=`fail` and notes=`develop não produziu código — orquestrador não despachou workers`. Report to the user:
       ```
       ✗ FALHA no develop: a fase reportou conclusão mas o working tree não mudou.
         O orquestrador provavelmente narrou o plano sem despachar os workers de implementação.
         Pipeline interrompido. Re-execute o develop ou implemente manualmente.
       ```
       Do NOT proceed to testing or quality phases.

### 3. PHASE: Testing

> **Phase check**: If `test` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 4.

Invoke the `ship:test` skill via the **Skill tool**. The skill declares `context: fork` + `model: "sonnet"` in its frontmatter — an orchestrator that resolves/de-identifies scenarios by layer and fans out Sonnet `ship-test-*` leaf workers, so it runs in an isolated subagent automatically — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Use the task's acceptance criteria to guide test generation
- Generate and run tests scoped to THIS task only
- Artifact language: `<artifact_language>`

**The forked skill MUST launch 3 sub-agents in parallel**: unit tests, integration tests, e2e tests.

**Scratch dir:** `.context/ship-run/<task-id>/`

If any test fails after fix attempts:
- The pipeline STOPS. Inform the user.
- Ask if they want an automatic fix attempt.

### 4. PHASES: Quality Checks (PARALLEL)

> **Phase check**: Check each quality phase individually against the **effective phase set** (resolved in step 1.5):
> - If all three (`perf`, `security`, `review`) are `disabled`: skip this step entirely and proceed to Phase 5.
> - If some are `disabled`: launch only the agents for enabled phases. Skip the disabled ones.

> **Pre-quality snapshot:** The snapshot `.context/ship-run/<task-id>/pre-quality-snapshot.sha` was already captured in step 0.5. All quality agents and the PR agent can read the HEAD SHA from that file. See `ship/patterns/gates.md → Snapshot pré-fix` for format details and lifecycle rules.

**Read diff class** before launching agents:

```bash
DIFF_CLASS=$(cat .context/ship-run/<task-id>/diff-class.txt)
```

Apply the per-class adjustments **on top of** the effective phase set exactly as specified in @ship/patterns/diff-classifier.md → "Behavior per Class" (which agents run, the log message, and the PASS rows to append to `phase-status.md`):

- **`trivial`**: all quality phases skipped → proceed directly to Phase 5 (gate=PASS).
- **`minor`**: only 1 combined security agent runs (`perf`/`review` skipped).
- **`normal`** or **`large`**: no adjustment — proceed with the standard agent setup below.

Invoke the quality phases in a SINGLE assistant turn so they run concurrently:
- **`perf`** (if enabled): dispatch via **Agent tool** with `subagent_type: ship:ship-perf` (named agent, runs with full Sonnet reasoning).
- **`security`** (if enabled): dispatch via **Agent tool** with `subagent_type: ship:ship-security` (named agent, runs with full Sonnet reasoning).
- **`review`** (if enabled): dispatch via **Skill tool** — declares `context: fork` + `model: "sonnet"` in its own frontmatter, so it runs in an isolated subagent automatically. Do NOT wrap it in an `Agent` tool call.

The orchestrator itself runs on Sonnet per @@ship/patterns/model-routing.md.

**Phase 1 — `perf`** *(only if `perf` is `enabled`)*. Dispatch via **Agent tool** with `subagent_type: ship:ship-perf`. Pass all context inline:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Project Type: <project-type>
Stack: <stack>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
Read the diff yourself from `.context/ship-run/<task-id>/diff.md` — the orchestrator already captured it there and does NOT inject it inline. Do not run `git diff`; analyze that file directly.
```

**Phase 2 — `security`** *(only if `security` is `enabled`)*. Dispatch via **Agent tool** with `subagent_type: ship:ship-security`. Pass all context inline:

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
Read the diff yourself from `.context/ship-run/<task-id>/diff.md` — the orchestrator already captured it there and does NOT inject it inline. Do not run `git diff`; analyze that file directly.
```

**Skill 3 — `ship:review`** *(only if `review` is `enabled`)*. Pass inline:
- Analyze the diff for this task only
- Write findings to `.context/ship-run/<task-id>/review-findings.md` (canonical scratch-dir path). In Linear mode, **do NOT** create `ship/changes/<feature>/` — the scratch dir is the only allowed write location.
- **Scratch dir:** `.context/ship-run/<task-id>/`
- Artifact language: `<artifact_language>`

### 5. GATE CHECK

After all 3 agents complete, apply severity overrides before gate evaluation:

**Severity Overrides:**
Read `Severity Overrides` from `ship/config.md`. For each override rule (e.g., `high → warn`), downgrade matching findings from all phase reports before evaluating the gate. If the field is absent, no downgrade is applied.

Evaluate the gate decision manually based on the aggregated findings from all quality agents:
- **FAIL** — any critical or high finding remains after severity overrides
- **WARN** — no critical/high findings, but at least one medium finding remains
- **PASS** — only low/info findings, or no findings at all

> **Compute the gate purely from the aggregated severity counts — you are NOT re-reviewing.** Do not reclassify, discount, or discard an individual finding because you personally believe it is a false positive. If you suspect a false positive, the correct path is still to honor `on_warn`/`on_fail`: the fix Agent inspects the code and, if there is nothing real to change, produces an empty fix — `@@ship/patterns/gates.md` → "Re-run: edge cases" Edge case 1 then records it as `fix sem mudanças — revisão manual necessária` and continues. Never declare `PASS` by overriding a worker's finding inline.

**Before handling gate results:** Read the `Gate Behavior` section from `ship/config.md`:
- `on_fail`: controls behavior for exit code 2 (`ask` | `fix` | `defer`). Default: `ask`.
- `on_warn`: controls behavior for exit code 1 (`ask` | `fix` | `pass`). Default: `ask`.

**If exit code 2 (FAIL):**
1. Present the critical/high findings to the user
2. Create tracking issues:
   - **Linear mode:** Create sub-issues linked to the current task via `mcp__linear-server__save_issue` with rich descriptions (Context, What to do, Acceptance Criteria)
   - **Local mode:** Record in `ship/changes/<feature>/tracking.md`
3. Act based on `on_fail`:
   - **`ask`**: Ask "I found issues that need fixing. Would you like me to apply the fixes automatically?" — if yes, fix; if no, pause.
   - **`fix`**: Inform "Auto-fixing issues per project config..."; **first capture the pre-fix snapshot** (Surgical Re-run Procedure → *Pre-fix snapshot* below), then launch an Agent to fix (**pass `model: "sonnet"` to the Agent tool call** — fixing is implementation reasoning), then apply the **Surgical Re-run Procedure** below using the set of phases that failed.
   - **`defer`**: Inform "Issues tracked for later (gate behavior: defer). Continuing pipeline..." and proceed to acceptance.

**If exit code 1 (WARN):**
1. Present warnings
2. Act based on `on_warn`:
   - **`ask`**: Ask "There are warnings. Fix now or proceed to acceptance?" — if fix, same flow as FAIL; if proceed, continue.
   - **`fix`**: Inform "Auto-fixing warnings per project config..."; **first capture the pre-fix snapshot** (Surgical Re-run Procedure → *Pre-fix snapshot* below), then apply fixes (**pass `model: "sonnet"` to the Agent tool call** — fixing is implementation reasoning), then apply the **Surgical Re-run Procedure** below using the set of phases that warned.
   - **`pass`**: Inform "Warnings noted (gate behavior: pass). Continuing to acceptance..." and proceed.

#### Surgical Re-run Procedure

> **Iteration limit**: Track a `$FIX_ITERATION` counter (starting at 1 for the first fix attempt). Before each fix attempt, check: if `$FIX_ITERATION > 3`, abort the pipeline immediately — inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária." Do NOT proceed to acceptance. Increment the counter after each fix.

> **Read `@@ship/patterns/gates.md` completely before applying this procedure.** Its rationale, edge cases, and scope mapping ("Snapshot pré-fix", "Re-run cirúrgico", "Re-run: edge cases") live there — including why working-tree snapshots are used instead of `git diff <sha> HEAD` (nothing commits mid-pipeline), the empty-fix and out-of-scope edge cases, and the `on_warn: fix` equivalence. This procedure applies to both `on_fail: fix` and `on_warn: fix`. The run-specific snapshot commands, output filenames, and iteration-counter mechanics below are authoritative.

**Pre-fix snapshot** — `bash "@@ship/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/pre-fix-files.txt`. Capture it **immediately before launching the fix Agent** (the FAIL/WARN `fix` handler routes here first).

After the fix agent completes, determine which quality phases to re-run:

1. **Read `on_fail_rerun`** from `ship/config.md → Gate Behavior` (values: `surgical` | `all`, default: `surgical` if absent).

2. **Compute the set of files the fix changed** (snapshot diff — no commits involved). Compute the post-fix snapshot and diff it against the pre-fix snapshot to list the entries new or content-changed since the pre-fix snapshot:

   ```bash
   bash "@@ship/hooks/snapshot-files.sh" snapshot .context/ship-run/<task-id>/post-fix-files.txt
   bash "@@ship/hooks/snapshot-files.sh" diff .context/ship-run/<task-id>/pre-fix-files.txt \
            .context/ship-run/<task-id>/post-fix-files.txt
   ```

   If the resulting file list is **empty** (fix made no working-tree changes), apply @@ship/patterns/gates.md → "Re-run: edge cases" Edge case 1: log `⚠ Fix não produziu mudanças. Re-run ignorado.`, append a `warn` row (notes=`fix sem mudanças — revisão manual necessária`) to `phase-status.md` for each phase that failed/warned, then skip all re-run logic and continue to acceptance.

3. **If `on_fail_rerun: all`**: re-run all quality phases that were originally enabled (same set as Phase 4). Skip the scope mapping below.

4. **If `on_fail_rerun: surgical`** (default):

   a. The modified files list was already computed in step 2 above.

   b. **Check for out-of-scope files**: if ANY modified file matches no phase scope rule, follow @@ship/patterns/gates.md → Edge case 4 (conservative mode — re-run ALL originally enabled quality phases in parallel as in Phase 4, log the `Fix tocou arquivo(s) fora do scope original` line, and skip to step 4f).

   c. **Apply the phase → scope mapping** from @@ship/patterns/gates.md ("Re-run cirúrgico → Phase → scope mapping", plus the `analyze` row in its analyze-scope section) for each phase that previously ran.

   d. **For each phase that previously ran**: compute the intersection of (modified files from the fix) and (phase scope). If the intersection is non-empty → re-run. If empty → skip.

   e. **Log the decision** before launching agents, in the format defined in @@ship/patterns/gates.md ("Re-run cirúrgico → Log format": `Fix tocou:` / `Re-run cirúrgico:` / `Re-run pulado:`).

   f. **Re-invoke only the selected phases** using the same dispatch pattern as Phase 4 (in parallel if multiple): `perf` and `security` via **Agent tool** with their respective `subagent_type` (`ship-perf`, `ship-security`); `review` via **Skill tool** (declares `context: fork` in its own frontmatter). Include `Artifact language: <artifact_language>` in each re-invocation, same as in Phase 4. Each re-invoked phase appends a new row to `phase-status.md` with run=`#<N>` (e.g., `#2` for first re-run) and notes=`re-run cirúrgico`.

5. **After re-run completes**: evaluate the gate decision again manually based on the new aggregated findings (same FAIL/WARN/PASS criteria as Phase 5). Handle the result using the same `on_fail`/`on_warn` logic — track `$FIX_ITERATION` to enforce the 3-iteration limit.

**If exit code 0 (PASS):**
Continue automatically.

### 6. PHASE: Analyze (Drift Detection)

> **Phase check**: If `analyze` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 7.

> **Invoke pattern**: This phase runs the `/ship:analyze` command. It orchestrates 2 agents in parallel then runs the correlation engine + report generation. If using `--analyze` flag on `ship run`, this phase is triggered automatically.

Invoke the `ship:analyze` skill via the **Skill tool**. The skill declares `context: fork` + `model: "sonnet"` in its frontmatter, so drift correlation (spec↔code↔tests) runs in an isolated subagent with full reasoning — do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Read the spec from `.context/ship-run/<task-id>/spec.md` and the design from `.context/ship-run/<task-id>/design.md` (the orchestrator wrote them there; not injected inline)
- Use the code diff from `.context/ship-run/<task-id>/diff.md`
- Run spec extraction and code/test extraction **in parallel** (2 internal sub-agents)
- Pass results to the Correlation Engine
- Generate the drift report + compute gate
- Persist `drift-report.md` and `drift-findings.json` to scratch dir
- Artifact language: `<artifact_language>`

**Scratch dir:** `.context/ship-run/<task-id>/`

**Mode-agnostic persistence:**
- **Linear mode:** Post `drift-findings.json` summary as a comment on the task issue via `mcp__linear-server__save_comment`
- **Local mode:** Export `drift-report.md` to `ship/changes/<feature>/drift-report.md`

**Monorepo support:** The agent detects which workspace is affected by inspecting diff paths. It filters spec requirements and test discovery to the detected workspace. If no workspace is detected, it analyzes the full repository.

**Gate behavior after ANALYZE:**
- Gate **FAIL** (critical/high findings) → act based on `on_fail` config (same flow as Phase 5)
- Gate **WARN** (medium findings) → act based on `on_warn` config (same flow as Phase 5)
- Gate **PASS** → continue to Phase 7

**Scope mapping for Surgical Re-run (if analyze phase fails/warns and needs re-run):** see @@ship/patterns/gates.md → "analyze phase scope mapping" — `analyze` has broad scope and re-runs whenever any file changed by the fix.

### 7. PHASE: User Acceptance

> **Phase check**: If `homolog` is `disabled` in the **effective phase set** (resolved in step 1.5), skip this phase entirely and proceed to Phase 8.

Invoke the `ship:homolog` skill via the **Skill tool**. Unlike the other phases, homolog is **not** forked — it is an interactive acceptance gate that must run in this same context so it can present the report, stop for the user's approval, and then transition the issue. Do NOT wrap it in an `Agent` tool call. Pass the following context inline:

- Consolidate findings into a quality report
- Present the report for this task
- Wait for user approval
- Artifact language: `<artifact_language>`

**Scratch dir:** `.context/ship-run/<task-id>/`

> **MANDATORY STOP — Await user response if homolog asks a question**
>
> The `ship:homolog` skill ends by either (a) approving the task or (b) asking
> the user a question (e.g., "Quais ajustes precisam ser feitos?", "Algo a
> corrigir antes do PR?"). If the homolog output contains an open question
> directed at the user, the orchestrator MUST stop immediately and return
> control to the user — do NOT continue to Step 8, do NOT run additional
> verification, do NOT mark the task as complete.
>
> Only proceed to Step 8 when the user has explicitly approved (e.g.,
> "aprovado", "pode seguir", "ok PR", or equivalent in the artifact language).
> If the user requests adjustments, treat it as a fix iteration: apply the
> changes, then re-invoke `ship:homolog` for re-approval.

### 8. MANDATORY STOP — Await user confirmation for PR

After homolog approval:

1. **Verify Linear lifecycle completion** (quality report comment + "Done" status).

   **Linear mode:**

   > **MANDATORY — Verify the full Linear lifecycle was completed (idempotent safety-net)**
   >
   > The `/ship:homolog` phase should have already posted the quality report comment and transitioned the issue to its completed state. This step only repairs a miss.
   > First, resolve the team's **completed**-state name following this recipe — **never pass the literal `"Done"`**:
   >
   > Read `@@ship/patterns/linear-status.md` and follow that recipe.
   > In parallel: call `mcp__linear-server__get_issue` (read its `state`) AND `mcp__linear-server__list_comments` to verify both:
   >
   > 1. If `state.type != "completed"` → call `mcp__linear-server__save_issue` with `state: <completed-state>` now.
   > 2. If the quality report comment is NOT present (i.e., no comment with a Summary table) → call `mcp__linear-server__save_comment` to post it now.
   >
   > Both the completed state AND the quality report comment are required before the task is considered complete. Do NOT use `get_issue_status` to read the issue's state.

   **Local mode:**
   - Write the consolidated report to `ship/changes/<feature>/report-<task-id>.md`
   - Mark the task as `done` in `tasks.md`

   **Both modes:** clean up temporary findings files.

2. Inform the user:
   - If working on multiple tasks: ask "Task '<name>' complete. Continue to the next task '<next-name>', or stop here?"
   - Otherwise: "**Task complete!** Run `/ship:pr` when ready to create a Pull Request."

3. **STOP HERE** — Do NOT invoke `/ship:pr` automatically.

4. Only proceed with PR creation when the user explicitly calls `/ship:pr`.

---

## Multi-task mode

When working on multiple tasks (`--project`, `--milestone`, or multiple IDs):

1. Sort tasks by **Linear milestone order** (deterministic field — never infer). Within a milestone, sort by issue creation date (also deterministic). Do NOT attempt dependency inference — task ordering stays deterministic and predictable, and that judgment call belongs to the user. If the user wants a different order, they pass explicit IDs in the desired sequence.
2. Process one task at a time through the full pipeline
3. After each task completion, ask the user before continuing
4. At the end, present a summary of all completed tasks

**Never process multiple tasks in parallel** — each task modifies code, so they must be sequential to avoid conflicts.

---

## Orchestrator Rules

- **1 task at a time by default**: Only work on multiple tasks if the user explicitly requests it.
- **Parallelism within phases is mandatory**: Quality checks ALWAYS run in parallel. Tests use 3 parallel agents.
- **Quality gates are non-negotiable for FAIL**: Critical/high findings MUST be resolved.
- **Line count awareness**: Warn (don't block) if a task exceeds 400 lines.
- **Respect pipeline phases**: Always build the **effective phase set** (step 1.5) before executing. Phases disabled by profile or explicit override MUST be skipped — inform the user: "Skipping [phase] (disabled in config)." and move to the next enabled phase.
- **Language**: Read `Artifact language` from `ship/config.md → Conventions` once in step 1.6 and inject the resolved value into every phase agent prompt. Phase SKILL.md files use this injected value and do not re-load `@ship/patterns/language.md` during pipeline execution.
- **Shared scratch dir**: See @ship/patterns/run-context.md for the `.context/ship-run/<task-id>/` structure and lifecycle.
- **Linear mode = zero local artifacts**: When Linear is configured, do NOT create `ship/changes/` directories. Task context comes from Linear, quality reports go as comments.
- **Local mode = full workspace**: When Linear is not configured, create all markdown artifacts locally.
- **Do not create the PR automatically**: The pipeline ends at acceptance. The user runs `/ship:pr` separately.
- **Each agent reads its command file**: This ensures each phase follows its own detailed instructions.
