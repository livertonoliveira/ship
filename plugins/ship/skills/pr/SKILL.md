---
name: ship:pr
description: "Creates a PR with atomic commits and an aggregated quality report. Run after homolog approval, or invoke directly to homologate-and-PR in one step."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship PR — Pull Request Creation

You are the Ship PR agent: create a PR with atomic commits, a descriptive branch, and a body aggregating the pipeline's quality reports.

**Input received:** $ARGUMENTS

---

## Storage mode & feature

Run the deterministic preflight once and act on its output — never re-derive these by hand:

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/pr-preflight.sh" --task <task-id> --feature <feature-name>
```

It prints `storage=` (linear|local — ${CLAUDE_SKILL_DIR}/patterns/storage-mode.md is the definition), `branch=`/`on_default_branch=`, `remote=`/`pr_base=` (pull, push and `--base` target these — never a hardcoded `origin`/`main`), `keep_context=` (`yes` = work-graph node: the graph polls this scratch dir and watches this PR's state on the forge), `pending_changes=`, `profile=`, `approval=` (local marker check; `unknown` in Linear — check cached comments), and one `gate_row:` per phase when the scratch dir exists.

Feature: **Linear** — `$ARGUMENTS` as issue ID/project name (ask if empty). **Local** — `$ARGUMENTS` as feature name in `ship/changes/`, else most recent feature with approved acceptance in `report.md`, else most recent feature folder (fast path below handles it).

---

## Prerequisites

### 1. Verify acceptance

- **Post-homolog:** `approval=present` (Linear: marker `- [x] User approves for PR` in cached comments). Continue.
- **Direct fast path:** marker absent. The explicit `/ship:pr` invocation **is** the approval — never ask the user to run `/ship:homolog` or for confirmation. Run **Implicit homologation** below, then continue.

Linear: fetch `get_issue` and `list_comments` in parallel, **cache both** — reused in Load Artifacts, Quality Report Aggregation, Step 8; never re-fetch `list_comments` elsewhere except where noted.

#### Implicit homologation (direct fast path only)

Mirrors `ship:homolog` Step 6.

1. Consolidate the quality report in memory (reused in the PR body, don't re-read later): the per-phase gate index is the preflight's `gate_row:` lines (most recent row per phase — never re-derive it by hand; `bash "${CLAUDE_SKILL_DIR}/hooks/pipeline.sh" rows` is the underlying source); for WARN/FAIL phases apply ${CLAUDE_SKILL_DIR}/patterns/lazy-load-findings.md to the findings file. Render via the PR Body Template's Quality Report structure (${CLAUDE_SKILL_DIR}/report-templates.md) plus `## Fixes Applied` (list or "None.") and a Homologation checklist. Missing scratch dir: note gate data unavailable, proceed anyway.
2. Record approval + close the issue:
   - **Linear** (parallel): `save_comment` with the report, Homologation set to `- [x] User has reviewed all changes / - [x] User has verified acceptance criteria / - [x] User approves for PR — Approved on YYYY-MM-DD (direct /ship:pr)`; transition via the full recipe in ${CLAUDE_SKILL_DIR}/patterns/linear-status.md (resolve → `save_issue` → verify `state.type == "completed"` → retry once; never pass literal `"Done"`; surface, don't proceed silently). Re-fetch `list_comments` once, replacing the cache.
   - **Local:** write/update `report.md` with the same report + Homologation block; mark `tasks.md` 4.1 completed.
3. Clean up temporary findings files (data now in the comment/report).
4. Log: "Direct PR — treated `/ship:pr` as homologation approval. Quality report posted and issue marked Done. Proceeding to PR creation."

### 2. Working-tree state

`pending_changes=` from the preflight — these become the atomic commits in Process step 3.

---

## Process

### 1. Load artifacts

**Linear:** if `.context/ship-run/<task-id>/linear/` holds `proposal.md` and `design.md`, read those — no fetch. Else if `.context/ship-run/<task-id>/linear-cache.json` exists, `get_document` per cached id (Proposal/Design), skipping `list_documents` (log `cached_at`, non-gating). Otherwise use ${CLAUDE_SKILL_DIR}/patterns/load-artifacts.md. Reuse cached `list_comments` from Prerequisites — do not re-fetch.

**Local:** ${CLAUDE_SKILL_DIR}/patterns/load-artifacts.md, plus `tasks.md` (completeness) and `report.md` (gates/findings).

### 2. Create branch

```bash
git checkout -b <branch-name>
```

Only if `on_default_branch=yes`; otherwise reuse `branch=` from the preflight.

### 3. Atomic commits

Analyze `git diff`/`git status`, group into atomic commits, stage per file (`git add <files>`, never `git add .` across multiple commits). Suggested order: infrastructure (types/schemas/migrations) → business logic → presentation → configuration → tests → quality fixes.

### 4. Land (one deterministic call)

```bash
bash "${CLAUDE_SKILL_DIR}/hooks/pr-land.sh" <task-id> [--summary <file>]
```

It runs the gate's own checks (skipped when the preflight printed `verified_tree=yes`), syncs onto `pr_base` with pr-sync.sh, pushes, writes the title and body from the commits and the gate rows (`--summary` replaces the Summary section with your own prose), opens the PR with `gh pr create --base <pr_base>`, arms GitHub's auto-merge for graph nodes (`keep_context=yes`), links and comments the PR in Linear and completes the issue when `LINEAR_API_KEY` is set, and runs pr-finalize.sh. Act on its `result=` line:

- `uncommitted` → step 3 first, then run it again.
- `red` → fix what `<scratch>/test-failures.md` lists, re-commit, run it again.
- `conflict files=…` → resolve every listed file **yourself, here**: you implemented this change and hold its intent, so never delegate it and never ask the user to arbitrate what you already know. Keep both sides' behavior. Then `bash "${CLAUDE_SKILL_DIR}/hooks/pr-sync.sh" --continue` and run it again. Ask the user only when the conflict encodes a product decision your task never made.
- `remote-branch-exists` → a PR is open or merged for this branch already; never rename it and never force-push — report it.
- `linear=mcp-needed` → `create_attachment` with the PR URL, `save_comment` with a one-line summary, then ${CLAUDE_SKILL_DIR}/patterns/linear-status.md to its completed state. **Local:** mark `tasks.md` items 4.2 and 4.3 completed.

**Strict profile** (preflight `profile=strict`): before landing, require the user to have run `/ship:audit:run` and report its gate — `FAIL` blocks the PR, `WARN` needs a literal `yes`, `PASS` continues. Audit commands are never invoked from inside the pipeline.

### 5. Finalize

Inform the user of the PR URL (`pr=`), commit count, and branch name (`branch=`).

- `keep_context=yes` and auto-merge armed: say auto-merge is armed and will complete once the forge's required checks pass — no action needed; the graph polls this PR and releases dependent nodes once it lands.
- `keep_context=yes` and arming failed: say auto-merge could not be armed (reason from the failed command); the graph merges the PR once the forge reports it CLEAN, unless its merge-policy is `human`.
- Otherwise: remind "Do NOT merge — review the PR and merge manually."

---

## Rules

- Standalone runs: never merge automatically — create the PR only, for a human to review.
- Graph nodes (`keep_context=yes`): arm GitHub's native auto-merge right after creating the PR — the pipeline's own gate already gated it green, and auto-merge still respects the forge's own required checks. This skill still never merges anything itself.
- Atomic commits, Conventional Commits, Co-Authored-By in every commit — never group unrelated changes.
- Never force-push unless explicitly requested.
- Language: ${CLAUDE_SKILL_DIR}/patterns/language.md.
- Never create a PR without recorded acceptance (Prerequisite 1) — always post the quality report and close the issue, never silently skip it.
- Archive the feature folder after PR creation (Local mode).
