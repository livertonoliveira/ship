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

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

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

1. **Consolidate the quality report.** Read `.context/ship-run/<task-id>/phase-status.md` for the per-phase gate (take the **last row** per phase). For each WARN/FAIL phase, read its findings file (`perf-findings`, `security-findings`, `review-findings`). Apply ---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

`phase-status.md` is the canonical gate index — it is **always** read first (in step 1.4 of homolog's "Load all artifacts"). The algorithm below assumes it is already in memory; do NOT re-read it.

---

## Algorithm

`phase-status.md` has structured columns: `Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes`.

For each phase (perf, security, review):

1. **Look up the gate** from the `phase-status.md` table — take the **last row** for that phase (most recent run).
   - If the phase has no row in `phase-status.md`: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md` and render per ## Quality Report {#quality-report}

Consolidated from `homolog.md`. Used in both Linear mode (as issue comment) and Local mode (as `report-<task-id>.md`).

Each findings section is rendered using the lazy-load algorithm — see the lazy-load-findings.md pattern (included above).

```markdown. Keep the consolidated report **in memory** for reuse in the PR body (do not rely on re-reading it later).
   - If the scratch dir / `phase-status.md` is missing (e.g., the pipeline ran in another context), produce a minimal report noting that gate data was unavailable, and proceed — do not block.
2. **Record approval + close the issue:**
   - **Linear mode** — in parallel:
     - `mcp__linear-server__save_comment`: post the consolidated quality report as a comment, with the Homologation section set to:
       ```
       - [x] User has reviewed all changes
       - [x] User has verified acceptance criteria
       - [x] User approves for PR — Approved on YYYY-MM-DD (direct /ship:pr)
       ```
     - Transition the issue to its completed state by following the **full** recipe in # Linear Status — resolve, set, and verify workflow-state transitions

> Canonical recipe for moving a task issue between workflow states.
> Used by `ship:run` / `ship:develop` (→ started) and `ship:homolog` / `ship:run` (→ completed).

A workflow-state **name** is team-configurable, so passing a hardcoded literal like `"In Progress"`
or `"Done"` to `save_issue` is unsafe: the `state` parameter is matched by state **name, type, or
ID**, and a team may have renamed it (e.g., `Em andamento`, `Concluído`, `Shipped`). When the name
does not match, the transition silently no-ops and the issue is left in its previous state.

Because a state **ID** never changes on rename, prefer resolving to the target state's **ID** and
passing that to `save_issue` — it is the only match key that cannot silently no-op. Fall back to the
state **name** only when an ID is not available. Either way, always verify (step 3) — verification is
what turns a silent no-op into a caught, retriable failure.

Likewise, `get_issue_status` does **not** read an issue's current state — it requires
`id` + `name` + `team` and returns the definition of a status entity. To read the state an issue is
currently in, use `get_issue` and inspect its `state` field.

Linear workflow states each have a stable `type`. The two the pipeline transitions to are:

| Transition | Linear state `type` | Config field captured at `ship:init` | Default name |
|------------|---------------------|--------------------------------------|--------------|
| Start work | `started`           | `In Progress Status`                 | `In Progress` |
| Complete   | `completed`         | `Done Status`                        | `Done` |

---

## 1. Resolve the target state (do this once per transition)

1. Read the relevant config field (`In Progress Status` or `Done Status`) and `Team ID` from
   `ship/config.md → Linear Integration`.
2. If the field is present and not `not configured`, use it as the target state name. To get the
   unambiguous **ID** (preferred — see below), call `mcp__linear-server__list_issue_statuses` with
   the `Team ID` and pick the state whose `type` matches the transition (`started`/`completed`),
   preferring the one whose name equals the configured name; use its `id`. If you cannot list
   statuses, fall back to passing the configured name.
3. If the config field is **absent** (older config) or `not configured`: call
   `mcp__linear-server__list_issue_statuses` with the `Team ID`, select the state whose `type`
   matches the transition (`started` or `completed`), and use its **`id`** as the target. If more
   than one state of that type exists, prefer the conventional name (`In Progress`/`Em andamento`
   for started; `Done`/`Concluído` for completed); otherwise take the first.

Call the resolved value `<target-state>` — an ID whenever one was obtained, otherwise a name.

## 2. Set the state

Call `mcp__linear-server__save_issue` with:
- `id`: the task issue identifier (e.g., `MOB-1147`)
- `state`: `<target-state>` — pass the resolved **ID** when available (immune to renames); a name
  only as the fallback.

## 3. Verify (never use `get_issue_status` for this)

Call `mcp__linear-server__get_issue` for the task issue and read its `state` field.
The transition succeeded when `state.type` matches the intended type (`started` or `completed`) —
a name-agnostic check.

If it does not match, the set failed — re-resolve `<target-state>` per step 1 (the configured name
may be stale), call `save_issue` again, and re-verify **once**. If it still fails, surface the issue
to the user with the resolved state name so they can fix the mapping in `ship/config.md` — do not
loop indefinitely. — resolve the target, call `mcp__linear-server__save_issue`, **then verify with `get_issue` that `state.type == "completed"` and retry once if it did not stick.** Do **not** pass the literal `"Done"` and do **not** stop after a single `save_issue` call: the set silently no-ops when the resolved name is stale, and this fast path has no later safety net. If it still fails after one retry, surface it to the user with the resolved value instead of proceeding silently.

       Then re-fetch `mcp__linear-server__list_comments` **once** and replace the cached result, so the downstream Quality Report Aggregation (Step 6) and Step C see the comment just posted.
   - **Local mode:** write/update `ship/changes/<feature>/report.md` with the consolidated report and the same Homologation block, and mark `tasks.md` item 4.1 as completed.
3. **Clean up** temporary findings files (`perf-findings`, `security-findings`, `review-findings`) — the data now lives in the comment/report.
4. **Log to the user (no question):** "Direct PR — treated `/ship:pr` as homologation approval. Quality report posted and issue marked Done. Proceeding to PR creation."

### 2. Verify there are no pending changes

Run `git status` to check the repository state.

---

## Process

### 1. Load artifacts

**Linear mode:**

Before calling `list_documents`/`get_document`, check whether `.context/ship-run/<task-id>/linear-cache.json` exists:
- **Cache hit**: read the file. Each document entry contains only `id` and `title` — use the `id` to call `get_document` for each key present (Proposal and/or Design), skipping `list_documents` entirely. Log the `cached_at` timestamp for traceability (e.g. "Using Linear cache from <cached_at>") but do not gate on it — the cache reflects documents at homolog-approval time and Linear docs may have changed since then.
- **Cache miss** (file absent or unreadable): fall through to the full flow in # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. as usual.

Then additionally load:
- Use the **cached `list_comments` result** from Prerequisites to read the quality report comment posted during homolog — do NOT call `list_comments` again

**Local mode:**

Follow the load-artifacts.md pattern (included above), then additionally load:
- `ship/changes/<feature>/tasks.md` — To verify completeness
- `ship/changes/<feature>/report.md` — For quality gates and findings

### 2. Create branch

```bash
git checkout -b <branch-name>
```

If already on a branch other than `main`/`master`, use the current branch.

### 3. Atomic commits

Analyze all changes with `git diff` and `git status`:

1. **Identify logical groups** of changes that should be separate commits
2. **Each commit must be atomic**: a single logical change that makes sense on its own
3. **Stage by file**: `git add <files>` (never `git add .` when making multiple commits)

**Suggested commit order:**
1. Infrastructure (types, interfaces, schemas, migrations)
2. Business logic (services, utilities)
3. Presentation layer (controllers, routes, components)
4. Configuration (module registration, route config)
5. Tests
6. Quality adjustments (review fixes, performance fixes)

### 4. Pre-push validation

Run the validations configured in `ship/config.md`:
- Typecheck (if configured)
- Tests (if configured)
- Lint (if configured)

If any validation fails: fix, re-commit, and re-run.

### 5. Push

```bash
git pull --rebase origin main
git push -u origin <branch-name>
```

If there are conflicts during rebase: resolve them. If ambiguous, ask the user for confirmation.

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

Apply the lazy-load algorithm from the lazy-load-findings.md pattern (included above) for each phase (perf, security, review).
For the exact rendering format (Lazy Mode — PASS table vs WARN/FAIL expanded block), see ## Lazy Mode {#lazy-mode}

Canonical rendering format for per-phase findings in quality reports and PR descriptions.
For the decision algorithm (how to determine PASS / WARN / FAIL), see the lazy-load-findings.md pattern (included above).

### Gate = PASS — tabela-resumo

When a phase gate = PASS, emit only the compact summary table row. **No findings content is embedded.**

Format:

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

Single-phase inline variant (used inside phase subsections):

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

**Example — all phases PASS:**

| Fase | Status | Findings críticos/altos |
|------|--------|------------------------|
| Performance | ✅ PASS | 0 |
| Security | ✅ PASS | 0 |
| Code Review | ✅ PASS | 0 |

### Gate = WARN or FAIL — bloco expandido

When a phase gate = WARN or FAIL, embed findings inline. Apply the filter:
- **Include in full**: all findings with severity `critical`, `high`, or `medium`
- **Aggregate**: replace all `low` findings with a single count line

Format:

```
### [HIGH] <Title>
<finding in Finding Entry format — see #finding-entry>

### [MEDIUM] <Title>
<finding in Finding Entry format>

+ N low-severity findings — [see full report](<link or path>)
```

**Example — Security gate = FAIL:**

### [HIGH] SQL Injection in search endpoint
- **Category:** INJ
- **File:** src/routes/search.ts:34
- **Description:** User input is interpolated directly into a raw SQL query without parameterization.
- **Impact:** Full database read/write access for an attacker.
- **Suggestion:** Use parameterized queries via the ORM or prepared statements.

### [MEDIUM] Missing rate limiting on login route
- **Category:** CFG
- **File:** src/routes/auth.ts:12
- **Description:** The POST /login endpoint has no rate limit, enabling brute-force attacks.
- **Impact:** Credential enumeration and account takeover.
- **Suggestion:** Apply a rate-limiting middleware (e.g., express-rate-limit) with a 5-attempts/minute threshold.

+ 3 low-severity findings — [see full report](https://linear.app/<workspace>/issue/<TEAM>-NNN)

---.

- **Linear mode:** extract each phase's findings from the quality report comment using the **cached `list_comments` result** from Prerequisites — do NOT call `list_comments` again. The link for each phase is the URL of that Linear comment.
- **Local mode:** read `ship/changes/<feature>/report-<task-id>.md`. The path for each phase is `ship/changes/<feature>/report-<task-id>.md`.

Follow ## PR Body Template {#pr-body}

Extracted from `pr.md`. Used by `/ship:pr` to build the pull request description via `gh pr create`.

```markdown for the PR body template.

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
> **Re-read the issue state.** Call `mcp__linear-server__get_issue` and confirm `state.type == "completed"`. The transition was supposed to happen during homolog approval or the implicit homologation in Prerequisite 1, but a `save_issue` no-op (stale state name) can leave it open silently. If `state.type != "completed"`, transition it now by following the full recipe in the linear-status.md pattern (included above) (resolve → set → verify), then continue.

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

Inform the user:
- URL of the created PR
- Number of commits made
- Branch name
- Remind: "Do NOT merge — review the PR and merge manually."

---

## Rules

- **Never merge automatically**: only create the PR
- **Atomic commits**: never group unrelated changes together
- **Conventional Commits**: ALWAYS follow the convention
- **Co-Authored-By**: ALWAYS include in every commit
- **Validation before push**: typecheck and tests must pass
- **Resolve conflicts**: if there are conflicts during rebase, resolve them (ask for confirmation if ambiguous)
- **Never force push**: unless the user explicitly requests it
- **Language**: Use the `artifact_language` injected in this prompt if available; otherwise read `Artifact language` from `ship/config.md → Conventions` per # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`..
- **Verify acceptance**: never create a PR without recorded acceptance. Acceptance is recorded either by a prior `/ship:homolog` approval or, on the direct fast path, by the explicit `/ship:pr` invocation itself (which triggers implicit homologation in Prerequisite 1) — never silently skip posting the quality report and closing the issue
- **Linear mode**: attach PR URL and post PR link comment, and verify the issue reached its completed state (Step C) — re-driving the transition only if a prior `save_issue` no-op left it open
- **Local mode**: archive the feature folder after PR creation
