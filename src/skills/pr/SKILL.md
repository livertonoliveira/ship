---
name: ship:pr
description: "Creates a PR with atomic commits and an aggregated quality report. Run after homolog approval, or invoke directly to homologate-and-PR in one step."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "haiku"
---

# Ship PR — Pull Request Creation

You are the Ship PR agent. Your mission is to create a complete Pull Request with atomic commits, a descriptive branch, and a rich body that aggregates the quality reports from the pipeline.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See @ship/patterns/storage-mode.md.

---

## Execution mode

Identify the feature:
- **Linear mode**: Use `$ARGUMENTS` as a Linear issue ID or project name. If empty, ask the user.
- **Local mode**: If `$ARGUMENTS` specifies a name, use it to find the feature in `ship/changes/`. If empty, prefer the most recent feature in `ship/changes/` (excluding `archive/`) that has approved acceptance in `report.md`; if none is approved, fall back to the most recent feature folder (the direct fast path below will homologate it).

---

## Prerequisites

### 1. Verify acceptance

`ship:pr` supports two entry paths:

- **Post-homolog (normal):** the user already ran `/ship:homolog` and approved. The approval marker exists — proceed straight to PR creation.
- **Direct (fast path):** the user invokes `/ship:pr` without having approved in homolog. **Invoking `/ship:pr` explicitly IS the acceptance approval** — do NOT stop, do NOT ask the user to run `/ship:homolog`, and do NOT ask for any confirmation. Instead, run the **Implicit homologation** sub-routine below (consolidate the quality report, post it, transition the issue to its completed state), then continue.

**Linear mode:**
- In parallel: use `mcp__linear-server__get_issue` to fetch the task issue AND `mcp__linear-server__list_comments` to fetch all issue comments — **cache this result** for reuse throughout this skill (Load artifacts, Quality Report Aggregation, and Step C below)
- Inspect the Homologation section in the cached comments:
  - **If it contains `- [x] User approves for PR`:** acceptance was already recorded by homolog. Continue to Prerequisite 2.
  - **If it does NOT:** run **Implicit homologation** (below), then continue to Prerequisite 2.

**Local mode:**
- Read `ship/changes/<feature>/report.md` (if it exists) and inspect the Homologation section:
  - **If it contains `- [x] User approves for PR`:** continue to Prerequisite 2.
  - **If it does NOT, or `report.md` is absent:** run **Implicit homologation** (below), then continue to Prerequisite 2.

#### Implicit homologation (direct fast path)

Triggered **only** when the approval marker is absent. The user's explicit `/ship:pr` is the approval — record it as such, silently, and mirror `ship:homolog` Step 6.

1. **Consolidate the quality report.** Read `.context/ship-run/<task-id>/phase-status.md` for the per-phase gate (take the **last row** per phase). For each WARN/FAIL phase, read its findings file (`perf-findings`, `security-findings`, `review-findings`). Apply @ship/patterns/lazy-load-findings.md and render per @ship/report-templates.md#quality-report. Keep the consolidated report **in memory** for reuse in the PR body (do not rely on re-reading it later).
   - If the scratch dir / `phase-status.md` is missing (e.g., the pipeline ran in another context), produce a minimal report noting that gate data was unavailable, and proceed — do not block.
2. **Record approval + close the issue:**
   - **Linear mode** — in parallel:
     - `mcp__linear-server__save_comment`: post the consolidated quality report as a comment, with the Homologation section set to:
       ```
       - [x] User has reviewed all changes
       - [x] User has verified acceptance criteria
       - [x] User approves for PR — Approved on YYYY-MM-DD (direct /ship:pr)
       ```
     - Transition the issue to its completed state by following the **full** recipe in @@ship/patterns/linear-status.md — resolve the target, call `mcp__linear-server__save_issue`, **then verify with `get_issue` that `state.type == "completed"` and retry once if it did not stick.** Do **not** pass the literal `"Done"` and do **not** stop after a single `save_issue` call: the set silently no-ops when the resolved name is stale, and this fast path has no later safety net. If it still fails after one retry, surface it to the user with the resolved value instead of proceeding silently.

       Then re-fetch `mcp__linear-server__list_comments` **once** and replace the cached result, so the downstream Quality Report Aggregation (Step 6) and Step C see the comment just posted.
   - **Local mode:** write/update `ship/changes/<feature>/report.md` with the consolidated report and the same Homologation block, and mark `tasks.md` item 4.1 as completed.
3. **Clean up** temporary findings files (`perf-findings`, `security-findings`, `review-findings`) — the data now lives in the comment/report.
4. **Log to the user (no question):** "Direct PR — treated `/ship:pr` as homologation approval. Quality report posted and issue marked Done. Proceeding to PR creation."

### 2. Verify there are no pending changes

`git status`

---

## Process

### 1. Load artifacts

**Linear mode:**

Before calling `list_documents`/`get_document`, check whether `.context/ship-run/<task-id>/linear-cache.json` exists:
- **Cache hit**: read the file. Each document entry contains only `id` and `title` — use the `id` to call `get_document` for each key present (Proposal and/or Design), skipping `list_documents` entirely. Log the `cached_at` timestamp for traceability (e.g. "Using Linear cache from <cached_at>") but do not gate on it — the cache reflects documents at homolog-approval time and Linear docs may have changed since then.
- **Cache miss** (file absent or unreadable): fall through to the full flow in @ship/patterns/load-artifacts.md as usual.

Then additionally load:
- Use the **cached `list_comments` result** from Prerequisites to read the quality report comment posted during homolog — do NOT call `list_comments` again

**Local mode:**

Follow @ship/patterns/load-artifacts.md, then additionally load:
- `ship/changes/<feature>/tasks.md` — To verify completeness
- `ship/changes/<feature>/report.md` — For quality gates and findings

### 2. Create branch

```bash
git checkout -b <branch-name>
```

If already on a branch other than `main`/`master`, use the current branch.

### 3. Atomic commits

Analyze all changes with `git diff` and `git status`, then group them into atomic commits — stage by file (`git add <files>`, never `git add .` when making multiple commits).

**Suggested commit order:**
1. Infrastructure (types, interfaces, schemas, migrations)
2. Business logic (services, utilities)
3. Presentation layer (controllers, routes, components)
4. Configuration (module registration, route config)
5. Tests
6. Quality adjustments (review fixes, performance fixes)

### 4. Pre-push validation

Run typecheck, tests, and lint as configured in `ship/config.md`. If any validation fails: fix, re-commit, and re-run.

### 5. Push

```bash
git pull --rebase origin main
git push -u origin <branch-name>
```

If there are conflicts during rebase: resolve them, asking the user for confirmation if ambiguous.

### Strict-exclusive: pre-PR audit gate

Read `ship/config.md` and extract `Pipeline Profile → profile`.

**If `profile: strict`:**

> **NOTE — audit commands MUST NOT be invoked from within the pipeline.**
> Audit commands (`/ship:audit:*`) are project-wide and must be triggered by the user separately.
> In strict mode, `ship:pr` enforces that the user has already run `/ship:audit:run` before creating the PR.

Inform the user:
```
Profile: strict — a full project audit is required before PR creation.
Please run /ship:audit:run now, then share here:
1. The consolidated gate result (PASS / WARN / FAIL)
2. A brief summary of findings by severity (e.g., "2 critical, 1 high, 3 medium" or "no findings")
```

Wait for the user to provide both the gate result and the findings summary. Accept only one of the following literal values for the gate result: `PASS`, `WARN`, or `FAIL` (case-insensitive). If the user provides only the gate word without a findings summary, ask them to also share the findings count or confirm "no findings". If the gate result is ambiguous, ask them to clarify.

Evaluate the gate result provided by the user:

- **Gate = FAIL**: Block PR creation immediately. Inform the user:
  ```
  PR creation blocked — audit gate: FAIL
  Resolve all critical and high findings before retrying /ship:pr.
  ```
  STOP — do not proceed to step 6.

- **Gate = WARN**: Pause. Ask the user to share the list of WARN (medium) findings from the audit report. Once they have shared the findings, present the confirmation:
  ```
  Audit gate: WARN — medium findings were detected (listed above).
  Answer exactly "yes" to proceed with PR creation, or "no" to stop.
  ```
  Accept only the literal word `yes` or `no` — ignore any other content.
  If the user answers **no**: STOP.
  If the user answers **yes**: continue to step 6.

- **Gate = PASS**: Continue to step 6 without interruption.

**If `profile: lite` or `profile: standard` (or profile is not set):**

Skip this step entirely — no audit gate is enforced.

---

### 6. Create PR

Build the PR body using the artifacts (from Linear documents or local files) and create via `gh pr create`.

#### Quality Report Aggregation

Apply the lazy-load algorithm from @ship/patterns/lazy-load-findings.md for each phase (perf, security, review).
For the exact rendering format (Lazy Mode — PASS table vs WARN/FAIL expanded block), see @ship/report-templates.md#lazy-mode.

- **Linear mode:** extract each phase's findings from the quality report comment using the **cached `list_comments` result** from Prerequisites — do NOT call `list_comments` again. The link for each phase is the URL of that Linear comment.
- **Local mode:** read `ship/changes/<feature>/report-<task-id>.md`. The path for each phase is `ship/changes/<feature>/report-<task-id>.md`.

Follow @ship/report-templates.md#pr-body for the PR body template.

Use a HEREDOC for the body:
```bash
gh pr create --title "<conventional commit style title>" --body "$(cat <<'EOF'
<body content>
EOF
)"
```

### 7. Update artifacts

**Linear mode:**

> **MANDATORY STEP A — Attach PR URL**
>
> Call `mcp__linear-server__create_attachment` with the PR URL to attach it to the issue.

> **MANDATORY STEP B — Post PR link comment**
>
> Call `mcp__linear-server__save_comment` to post a comment on the issue with the PR URL.
> The comment must include the PR URL and a brief summary (e.g., "PR created: <url>").

> **MANDATORY STEP C — Verify the quality report, the PR link, AND the issue state**
>
> The quality report comment was already verified via the cached result from Prerequisites — no extra call needed for it.
> Use the **cached `list_comments` result** to confirm the quality report is present. If it is missing, warn the user (homolog did not complete properly).
> The PR link comment was just posted above (Step B) — trust it succeeded unless the call returned an error.
>
> **Re-read the issue state.** Call `mcp__linear-server__get_issue` and confirm `state.type == "completed"`. The transition was supposed to happen during homolog approval or the implicit homologation in Prerequisite 1, but a `save_issue` no-op (stale state name) can leave it open silently. If `state.type != "completed"`, transition it now by following the full recipe in @@ship/patterns/linear-status.md (resolve → set → verify), then continue.

**Local mode:**
1. Update `tasks.md`: mark item 4.2 (PR created) as completed
2. Update `tasks.md`: mark item 4.3 as completed (if applicable)

### 8. Clean up shared scratch dir

After the PR is created successfully and the trace is finalized:

1. Check whether the `--keep-context` flag was passed as an argument (e.g., `/ship:pr MOB-1149 --keep-context`).
   - If `--keep-context` is present: **skip this step entirely**. Log to the user: "Scratch dir preserved for inspection: `.context/ship-run/<task-id>/`"
2. Otherwise, remove the task's scratch directory:
   ```bash
   rm -rf .context/ship-run/<task-id>
   ```
   Where `<task-id>` is the Linear issue ID (e.g., `MOB-1149`) or the feature slug in local mode.
   Log to the user: "Scratch dir cleaned up."

> **Note:** Never remove the parent `.context/ship-run/` directory — other parallel pipelines may be using it.

---

### 9. Archive feature (Local mode only)

**Local mode:**
Move the feature folder to the archive:
```bash
mv ship/changes/<feature-name> ship/changes/archive/$(date +%Y-%m-%d)-<feature-name>
```

**Linear mode:**
No local files to archive. Linear artifacts remain in Linear.

### 10. Finalize

Inform the user of the PR URL, number of commits, and branch name. Remind: "Do NOT merge — review the PR and merge manually."

---

## Rules

- **Never merge automatically**: only create the PR
- **Atomic commits**: never group unrelated changes together
- **Conventional Commits**: ALWAYS follow the convention
- **Co-Authored-By**: ALWAYS include in every commit
- **Validation before push**: typecheck and tests must pass
- **Resolve conflicts**: if there are conflicts during rebase, resolve them (ask for confirmation if ambiguous)
- **Never force push**: unless the user explicitly requests it
- **Language**: per @ship/patterns/language.md.
- **Verify acceptance**: never create a PR without recorded acceptance. Acceptance is recorded either by a prior `/ship:homolog` approval or, on the direct fast path, by the explicit `/ship:pr` invocation itself (which triggers implicit homologation in Prerequisite 1) — never silently skip posting the quality report and closing the issue
- **Linear mode**: attach PR URL and post PR link comment, and verify the issue reached its completed state (Step C) — re-driving the transition only if a prior `save_issue` no-op left it open
- **Local mode**: archive the feature folder after PR creation
