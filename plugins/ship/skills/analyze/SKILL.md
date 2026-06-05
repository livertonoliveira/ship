---
name: ship:analyze
description: "Ship Phase 6.5: drift detection — maps spec→code→tests, detects gaps, gate PASS/WARN/FAIL."
argument-hint: "<feature-name | linear-issue-id>"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Analyze — Skill Wrapper

Parse arguments and delegate to the `ship-analyze` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the feature name or Linear issue ID from `$ARGUMENTS`:
- A Linear issue ID (e.g., `MOB-123`) → spec is loaded from Linear.
- A feature name → spec is loaded from `ship/changes/<feature>/`.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Test Scope` → enabled/disabled state per layer (`unit`, `integration`, `e2e`); absent → treat all as enabled
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Resolve diff and spec

**If `$ARGUMENTS` already contains `## Diff` / `## Spec` sections** (injected inline by the orchestrator), use them directly — skip file reads, git commands, and Linear lookups.

**Otherwise:**

Diff:
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred).
- Otherwise → run `git diff origin/main...HEAD` (canonical range per `# Run Context — Shared Scratch Between Agents

Temporary scratch pattern used by the `/ship:run` orchestrator to share context
between phase agents (develop, test, perf, security, review).

---

## Root directory

```
.context/ship-run/<task-id>/
```

`<task-id>` is the Linear issue identifier (e.g., `MOB-1140`) or, in local mode,
the feature slug (e.g., `my-feature`). The directory is ephemeral — never commit it
(see `.gitignore`).

> **`<task-id>` must contain only `[a-zA-Z0-9_-]`. Never use values containing `/`, `..`, or spaces.**

---

## Canonical files

| File | Written by | Read by | Content |
|------|-----------|---------|---------|
| `stack.md` | orchestrator (run) | all agents | detected stack summary — language, runtime, framework, test runner |
| `diff.md` | orchestrator (run) — baseline at init, refreshed after develop | perf, security, review | working-tree diff of the branch vs the merge-base (incl. untracked) — full diff of new/modified code |
| `plan.md` | plan skill (`ship:plan`) | develop, test | module map (disjoint file sets, dependencies, scenario→module) + test contract (scenario→layer→file slots) — the single source of truth both develop and test derive from. Absent when the planner is skipped — only for a `trivial`/`minor` *baseline* diff (a small change on top of pre-existing work); greenfield tasks always run the planner. |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `phase-status.md` | orchestrator (creates); agents (append) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `pre-quality-snapshot.sha` | orchestrator (run) | — | baseline HEAD SHA before quality phases (diagnostic; nothing commits mid-pipeline, so HEAD does not move and the PR diff is built from the working tree) |
| `pre-fix-files.txt` / `post-fix-files.txt` | orchestrator (run) | orchestrator (re-run) | per-file content snapshots (`<hash> <path>`) taken before/after the auto-fix Agent — diffed to scope the surgical re-run |
| `jaccard.json` | analyze agent | analyze agent (re-run) | Jaccard similarity matrix cache — keyed by diff + spec SHA-256 hashes; reused when hashes match to avoid redundant computation |

### `stack.md` format

```markdown
# Stack

- Language: TypeScript
- Runtime: Node.js 20+
- Framework: NestJS
- Test runner: vitest
- Package manager: npm
```

### `diff.md` format

Literal, untruncated output of the branch's **working-tree** diff against the merge-base, including untracked files:

```bash
BASE=$(git merge-base origin/main HEAD)
git add -A -N   # surface untracked files; the scratch dir is gitignored and never added
git diff "$BASE"
```

The orchestrator writes it **twice**: a provisional baseline during init (step 0.5, before any code exists) and an authoritative refresh after `ship:develop` (step 2.5). The refresh is required because `ship:develop` writes code to the working tree without committing — an init-only, HEAD-based diff would be empty and the quality phases would analyze nothing. Standalone invocations (no scratch dir) fall back to `git diff origin/main...HEAD`, where the work under analysis is already committed.

### `test-failures.md` format

Always written by the test agent — even if all tests passed (header-only = zero failures):

```markdown
# Test Failures

- src/auth/auth.service.ts (3 failures)
- src/users/users.repo.ts (1 failure)
```

When all tests pass, the file contains only the header:

```markdown
# Test Failures
```

Header-only (no bullet items) or absent file both indicate all tests passed.

### `phase-status.md` format

Each phase appends one row when it completes. Re-run iterations appear as additional rows with incremented run numbers. Timestamps are ISO-8601 UTC.

```markdown
# Phase Status

| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |
|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|
| develop | #1 | 2026-05-01T10:00:00Z | - | pass | 0 | 0 | 0 | 0 | |
| test | #1 | 2026-05-01T10:01:00Z | - | pass | 0 | 0 | 0 | 0 | |
| perf | #1 | 2026-05-01T10:02:00Z | src/runner.ts | warn | 0 | 0 | 2 | 1 | N+1 query detected |
| security | #1 | 2026-05-01T10:02:00Z | src/runner.ts, config.ts | pass | 0 | 0 | 0 | 0 | |
| review | #1 | 2026-05-01T10:02:00Z | src/runner.ts | pass | 0 | 0 | 0 | 0 | |
| perf | #2 | 2026-05-01T10:05:00Z | src/runner.ts | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### `pre-quality-snapshot.sha` format

Single-line file with the commit SHA:

```
a1b2c3d4e5f6...
```

### `jaccard.json` format

Written and read by the `analyze` agent (pipeline mode only). Invalidated whenever `diff_hash` or `spec_hash` changes.

```json
{
  "diff_hash": "<sha256 of diff.md content>",
  "spec_hash": "<sha256 of concatenated REQ-XX/AC-XX descriptions>",
  "matrix": {
    "REQ-01": { "code": ["src/foo.ts:10"], "score": 0.7 },
    "REQ-02": { "code": ["src/bar.ts:55"], "score": 0.3 },
    "AC-01":  { "tests": ["test/foo.test.ts:42"], "score": 0.9 },
    "AC-02":  { "tests": [], "score": 0.0 }
  }
}
```

- `diff_hash` and `spec_hash` are used as a compound cache key. If either changes, the entire matrix is recomputed.
- `matrix` maps each REQ-XX/AC-XX ID to its best-match file(s) and highest Jaccard score.
- `code` lists matched source file locations (`<path>:<line>`); `tests` lists matched test file locations.
- Absent file means the cache was computed in standalone mode (no scratch dir) — no `jaccard.json` is written in that case.

---

## Read/write conventions

- **Orchestrator** (`run.md`): sole owner of **creating** the directory and **writing**
  `stack.md`, `diff.md`, and `pre-quality-snapshot.sha` before launching any agent.
  Also creates `phase-status.md` with the empty header row at pipeline start. The orchestrator
  **refreshes `diff.md` (and `diff-class.txt`) once more after the develop phase** — it is the
  only file rewritten mid-pipeline, and only by the orchestrator itself.
- **Planner** (`ship:plan`): sole writer of `plan.md`, before develop and test run. It is the
  one phase that produces (rather than only reads) a shared artifact other phases consume.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files
  (develop and test read `plan.md`).
  The only write allowed is **appending** rows to `phase-status.md` upon phase completion.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files (baseline `diff.md`) |
| After develop phase | Orchestrator refreshes `diff.md` + `diff-class.txt` over the post-develop working tree (authoritative) |
| During pipeline | Agents read and append as needed |
| End of `/ship:pr` | Orchestrator removes `.context/ship-run/<task-id>/` (recursive) |
| `--keep-context` flag in `/ship:pr` | Directory is preserved for manual inspection |

The parent directory `.context/ship-run/` may hold multiple `<task-id>/` subdirs if
parallel pipelines are running — never remove the parent, only the completed task's subdir.

---

## Inline context slicing (fan-out optimization)

When the orchestrator dispatches N parallel sub-agents, each agent opens a fresh conversation with no shared prompt cache. Passing large shared artifacts (diff, Design, proposal) to every agent multiplies token costs: **N × file size + N × cache miss**.

**Pattern:** the orchestrator reads each shared artifact **once**, slices it into per-agent subsets, and passes the slice **inline** in each agent's prompt. Agents must never re-read the original file.

### Slicing rules

- Always include enough surrounding context for the agent to understand scope:
  - For diffs: include the `diff --git a/...` file header + the full `@@ ... @@` hunk header + ±3 surrounding context lines for each included hunk.
  - For design/proposal docs: include the full subsection (heading + body) relevant to the agent's scope.
- If a hunk or section does not clearly belong to any agent's scope, include it in **all** agents' slices (conservative fallback).
- The orchestrator must not truncate content that agents need to make correct decisions — smaller is better, but correctness comes first.

### Which phases use this pattern

| Phase | Shared artifact sliced | Slice dimension |
|-------|------------------------|-----------------|
| `ship:security` | diff | by OWASP category (Injection / Auth / Data+Config) |
| `ship:test` | `plan.md` test contract (fallback: scenarios + file list) | by test layer (unit / integration / e2e) |
| `ship:develop` | `plan.md` module map (fallback: Design document) | by module / independent implementation unit |`).

Spec:
- Linear mode → loaded by the agent from the Linear issue + Proposal/Design documents (issue body carries the full Gherkin `## Scenarios`).
- Local mode → loaded by the agent from `ship/changes/<feature>/proposal.md`, `design.md`, and `tasks.md`.

## 4. Invoke ship-analyze agent

Use the Agent tool with `subagent_type: ship:ship-analyze`. Pass all context inline in the prompt:

```
Task: <task-id or feature-name>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Test Scope: <e.g., { unit: enabled, integration: disabled, e2e: disabled }>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content, or note "read from scratch dir / git" if not resolved here>

## Spec
<inline: spec reference — Linear issue ID or local feature path>
```

The agent orchestrates the 2 parallel extraction agents, runs the Jaccard correlation engine, classifies gaps, writes the drift report, and returns the gate decision. Return the agent's full output verbatim as your final message.
