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
bash "@@ship/hooks/pr-preflight.sh" --task <task-id> --feature <feature-name>
```

It prints `storage=` (linear|local — @@ship/patterns/storage-mode.md is the definition), `branch=`/`on_default_branch=`, `pending_changes=`, `profile=`, `approval=` (local marker check; `unknown` in Linear — check cached comments), and one `gate_row:` per phase when the scratch dir exists.

Feature: **Linear** — `$ARGUMENTS` as issue ID/project name (ask if empty). **Local** — `$ARGUMENTS` as feature name in `ship/changes/`, else most recent feature with approved acceptance in `report.md`, else most recent feature folder (fast path below handles it).

---

## Prerequisites

### 1. Verify acceptance

- **Post-homolog:** `approval=present` (Linear: marker `- [x] User approves for PR` in cached comments). Continue.
- **Direct fast path:** marker absent. The explicit `/ship:pr` invocation **is** the approval — never ask the user to run `/ship:homolog` or for confirmation. Run **Implicit homologation** below, then continue.

Linear: fetch `get_issue` and `list_comments` in parallel, **cache both** — reused in Load Artifacts, Quality Report Aggregation, Step 8; never re-fetch `list_comments` elsewhere except where noted.

#### Implicit homologation (direct fast path only)

Mirrors `ship:homolog` Step 6.

1. Consolidate the quality report in memory (reused in the PR body, don't re-read later): the per-phase gate index is the preflight's `gate_row:` lines (most recent row per phase — never re-derive it by hand; `bash "@@ship/hooks/pipeline.sh" rows` is the underlying source); for WARN/FAIL phases apply @@ship/patterns/lazy-load-findings.md to the findings file. Render via the PR Body Template's Quality Report structure (@@ship/report-templates.md) plus `## Fixes Applied` (list or "None.") and a Homologation checklist. Missing scratch dir: note gate data unavailable, proceed anyway.
2. Record approval + close the issue:
   - **Linear** (parallel): `save_comment` with the report, Homologation set to `- [x] User has reviewed all changes / - [x] User has verified acceptance criteria / - [x] User approves for PR — Approved on YYYY-MM-DD (direct /ship:pr)`; transition via the full recipe in @@ship/patterns/linear-status.md (resolve → `save_issue` → verify `state.type == "completed"` → retry once; never pass literal `"Done"`; surface, don't proceed silently). Re-fetch `list_comments` once, replacing the cache.
   - **Local:** write/update `report.md` with the same report + Homologation block; mark `tasks.md` 4.1 completed.
3. Clean up temporary findings files (data now in the comment/report).
4. Log: "Direct PR — treated `/ship:pr` as homologation approval. Quality report posted and issue marked Done. Proceeding to PR creation."

### 2. Working-tree state

`pending_changes=` from the preflight — these become the atomic commits in Process step 3.

---

## Process

### 1. Load artifacts

**Linear:** if `.context/ship-run/<task-id>/linear-cache.json` exists, `get_document` per cached id (Proposal/Design), skipping `list_documents` (log `cached_at`, non-gating). Otherwise use @@ship/patterns/load-artifacts.md. Reuse cached `list_comments` from Prerequisites — do not re-fetch.

**Local:** @@ship/patterns/load-artifacts.md, plus `tasks.md` (completeness) and `report.md` (gates/findings).

### 2. Create branch

```bash
git checkout -b <branch-name>
```

Only if `on_default_branch=yes`; otherwise reuse `branch=` from the preflight.

### 3. Atomic commits

Analyze `git diff`/`git status`, group into atomic commits, stage per file (`git add <files>`, never `git add .` across multiple commits). Suggested order: infrastructure (types/schemas/migrations) → business logic → presentation → configuration → tests → quality fixes.

### 4. Pre-push validation

Run typecheck, tests, and lint per `ship/config.md`. On failure: fix, re-commit, re-run.

### 5. Push

```bash
git pull --rebase origin main
git push -u origin <branch-name>
```

Resolve rebase conflicts, asking the user if ambiguous.

### 6. Strict-profile audit gate

Skip unless the preflight printed `profile=strict`.

Audit commands are never invoked from inside the pipeline — require the user to have already run `/ship:audit:run` and report the gate (`PASS`/`WARN`/`FAIL`, case-insensitive) plus a findings summary; ask again if missing/ambiguous.
- **FAIL:** block PR creation, tell the user to resolve critical/high findings, STOP.
- **WARN:** ask for the findings list, then require a literal `yes`/`no` to proceed; `no` → STOP.
- **PASS:** continue.

### 7. Create PR

#### Quality Report Aggregation

Apply the lazy-load algorithm at @@ship/patterns/lazy-load-findings.md per phase (perf, security, review). **Linear:** findings come from the cached quality-report comment (from Prerequisites); link = that comment's URL. **Local:** read `ship/changes/<feature>/report-<task-id>.md`; path = same file.

Build the body from the loaded artifacts following the PR Body Template section of @@ship/report-templates.md, then create via HEREDOC:

```bash
gh pr create --title "<conventional commit style title>" --body "$(cat <<'EOF'
<body content>
EOF
)"
```

### 8. Update artifacts

**Linear (all mandatory):** `create_attachment` with the PR URL; `save_comment` with the PR URL and a brief summary; re-`get_issue`, confirm `state.type == "completed"` — a stale-name `save_issue` no-op earlier can leave it open, so re-run @@ship/patterns/linear-status.md if needed.

**Local:** mark `tasks.md` items 4.2 and 4.3 (if applicable) completed.

### 9. Clean up & archive (one deterministic call)

```bash
bash "@@ship/hooks/pr-finalize.sh" <task-id> [--keep-context] [--feature <feature-name>]
```

Pass `--keep-context` only if the user asked for it (log the printed `context=` result); pass `--feature` in Local mode only (Linear has nothing to archive). It removes the task's scratch dir — never the shared parent — and archives `ship/changes/<feature>` under `archive/<date>-<feature>`.

### 10. Finalize

Inform the user of the PR URL, commit count, and branch name. Remind: "Do NOT merge — review the PR and merge manually."

---

## Rules

- Never merge automatically — create the PR only.
- Atomic commits, Conventional Commits, Co-Authored-By in every commit — never group unrelated changes.
- Never force-push unless explicitly requested.
- Language: @@ship/patterns/language.md.
- Never create a PR without recorded acceptance (Prerequisite 1) — always post the quality report and close the issue, never silently skip it.
- Archive the feature folder after PR creation (Local mode).
