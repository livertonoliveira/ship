---
name: ship:homolog
description: "Ship Phase 7: presents a consolidated quality report and awaits user acceptance approval."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Homolog — User Acceptance

You are the Ship acceptance agent. Consolidate all pipeline results into a final report, present it to the user, and obtain approval before the PR.

> **Intentionally NOT forked** (matching `ship:init`/`ship:pr`): homologation is an **interactive gate** — it presents the report, stops for approval, then transitions the issue. A forked subagent returns control before the human answers, so post-approval steps (set Done, post comment) would never run. Do not re-add `context: fork`.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

---

## Execution mode

Identify the feature/task ID from `$ARGUMENTS`. Prefer the scratch dir `.context/ship-run/<task-id>/` (pre-populated `phase-status.md` and findings) when present; else fall back to local artifact files.

---

## Process

### 1. Load all artifacts

- **Linear mode**: in parallel, `mcp__linear-server__get_issue` (task details: title, description, AC, status, labels) AND `mcp__linear-server__get_project`. Then `list_documents` **once**, then in parallel `get_document` for **Proposal** and **Design** (IDs from that single `list_documents` call).
- **Local mode**: follow `${CLAUDE_SKILL_DIR}/patterns/load-artifacts.md`, then additionally load `ship/changes/<feature>/report.md` (if consolidated) and `ship/changes/<feature>/tracking.md` (if it exists).
- **Both modes**: get the canonical per-phase gate index with `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" rows .context/ship-run/<task-id>` — it prints the most recent row per phase (columns Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes); never re-derive "last row per phase" by hand. Local mode treats a missing row as FAIL. For each phase where gate = WARN or FAIL, read its findings file (`perf-findings[-<task-id>].md`, `security-findings[-<task-id>].md`, `review-findings[-<task-id>].md`); do **not** open findings files for PASS phases.

### 2. Consolidate quality report — lazy-load findings

Apply `${CLAUDE_SKILL_DIR}/patterns/lazy-load-findings.md`, using `phase-status.md` (loaded in step 1) as the canonical gate index — only WARN/FAIL phases get their findings files opened. Rendering format (PASS table vs WARN/FAIL expanded block) and full report structure: read `${CLAUDE_SKILL_DIR}/report-templates.md`, sections "Lazy Mode" and "Quality Report".
Linear mode: report becomes a comment (no local file). Local mode: report is written to `report.md`.

### 3. Verify task completeness

- Linear mode: read the issue description; confirm all acceptance criteria are addressed and all quality checks executed.
- Local mode: read `tasks.md`; confirm Section 1 (Implementation) and Section 2 (Testing) items are complete, and check which Section 3 (Quality) checks passed.

If any critical item is not completed, flag it to the user.

### 4. Present the report to the user

Follow `${CLAUDE_SKILL_DIR}/report-templates.md`, section "Acceptance Report". After the gate summary, append a `## Execution Trace` section by reading `.context/ship-run/<task-id>/dispatch-log.md` (if it exists) and rendering its table verbatim — shows per-dispatch tool (Skill vs Agent), worker name, model. Omit if the file is missing or has only the header.

### 5. Await approval

Ask: "Review the acceptance criteria above. Is the feature ready for PR?"
- Approved: Linear mode proceeds straight to Conclusion; Local mode also marks the acceptance items in `report.md` and `tasks.md` item 4.1 as completed.
- Adjustments requested: record what needs to change and inform the user corrections can be made before running `/ship:pr` (both modes).

### 6. Conclusion

**Local mode** — after approval:
1. Update `report.md` Homologation section: `- [x] User has reviewed all changes` / `- [x] User has verified acceptance criteria` / `- [x] User approves for PR — Approved on YYYY-MM-DD`
2. Update `tasks.md` item 4.1 as completed
3. Clean up temporary findings files (perf/security/review) — already consolidated in `report.md`
4. Inform: "Acceptance approved! Run `/ship:pr` when you are ready to create the Pull Request."

**Linear mode** — after approval, execute ALL steps below, none may be skipped:

> **STEPS A+B (parallel) — post report comment AND transition issue to completed state**
> Resolve the team's completed-state name via the recipe in `${CLAUDE_SKILL_DIR}/patterns/linear-status.md` first — **never pass the literal string `"Done"`**, it silently no-ops on teams whose completed state is named differently (e.g. `Concluído`).
> In parallel: `mcp__linear-server__save_comment` posts the full quality report on the task issue, Homologation section marked `- [x]` for reviewed/verified/approved (with date) as above; AND `mcp__linear-server__save_issue` with `state: <resolved completed-state>`. Both are mandatory.

> **STEP C — verify both succeeded**
> In parallel: `mcp__linear-server__list_comments` (confirm the comment posted) AND `mcp__linear-server__get_issue` (confirm `state.type == "completed"`). Do not use `get_issue_status` (returns a status definition, not the issue's current state). Retry any failed step per the Step A/B recipe.

> **STEP D — write Linear document cache**
> Write `.context/ship-run/<task-id>/linear-cache.json` (via `mkdir -p` then Bash write) so `ship:pr` can skip redundant `list_documents`/`get_document` calls:
> ```json
> { "cached_at": "<ISO 8601 timestamp>", "proposal": { "id": "...", "title": "..." }, "design": { "id": "...", "title": "..." } }
> ```
> Omit any key whose document wasn't found — never write `null`. `ship:pr` logs `cached_at` but must not gate on it (docs may have changed since). Best-effort: on write failure, log a warning and continue — never block homolog.

> **STEP E — cleanup and inform**
> Delete temporary findings files (perf/security/review) — data now lives in the Linear comment. Inform: "Acceptance approved! The issue is marked Done and the quality report is on the issue. Run `/ship:pr` when you are ready to create the Pull Request."

---

## Rules

- **Do not make decisions for the user**: present the data and let the user approve or reject
- **Be transparent with warnings**: do not minimize medium-level findings. Present them clearly.
- **Acceptance criteria belong to the user**: present them as a checklist for manual verification, not as automated tests
- **Language**: per `${CLAUDE_SKILL_DIR}/patterns/language.md`.
- **Do not proceed without approval**: acceptance is a manual gate, never automatic
- **Linear mode**: quality report is posted as a comment on the task issue, no local report.md is created
- **Local mode**: quality report is written to report.md in the feature directory
