---
name: ship:review
description: "Ship Phase 6: code review focused on SOLID, DRY, KISS, Clean Code, and project consistency."
argument-hint: "<feature-name | task-id>"
allowed-tools: Read, Bash, Agent
user-invocable: true
model: haiku
context: fork
---

# Ship Review — Skill Wrapper

Parse arguments and delegate to the `ship-review` named agent.

**Input received:** $ARGUMENTS

---

## 1. Parse arguments

Extract the task identifier or feature name from `$ARGUMENTS`.

## 2. Load minimal context

Read `ship/config.md`:
- `Linear Integration → Configured` → storage mode (`yes` = Linear, `no` = local)
- `Conventions → Artifact language` → e.g., `pt-BR`
- `Stack` → e.g., Node.js, Next.js, NestJS
- `Severity Overrides` → downgrade rules (if present)

Resolve scratch dir: `.context/ship-run/<task-id>/`

## 3. Resolve diff

**If `$ARGUMENTS` already contains a `## Diff` section** (injected inline by the orchestrator), use it directly — skip file reads and git commands.

**Otherwise:**

- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → run `git diff origin/main...HEAD` to obtain the diff (canonical range per `# Run Context — Shared Scratch Between Agents

Temporary scratch pattern used by the `/ship:run` orchestrator to share context
between phase agents (develop, test, perf, security, review, analyze). `perf`,
`security`, `review`, and `analyze` all dispatch in the same Phase 4 parallel
turn and feed a single aggregated gate in Phase 5 — see `run/SKILL.md` → Phase
4/5.

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
| `diff.md` | orchestrator (run) — baseline at init, refreshed after develop | perf, security, review, analyze | working-tree diff of the branch vs the merge-base (incl. untracked) — full diff of new/modified code |
| `spec.md` | orchestrator (run) — once, in step 1 | plan, develop, analyze | per-task slice of the spec: full issue description (Context, What to do, Files section if present, Acceptance Criteria, Scenarios, Notes) + full text of only the requirement sections (REQ-XX) from the Proposal covering this issue's acceptance criteria + a compact scope index (one line per remaining requirement in the feature not included in full — title and covering issue when known) so later phases know what is out of scope without loading its full text. Written once so phases read it instead of receiving it re-inlined per dispatch |
| `design.md` | orchestrator (run) — once, in step 1 | plan, develop, analyze | full Design document. Written once; `develop` slices it per module when fanning out workers |
| `plan.md` | plan skill (`ship:plan`) | develop, test | module map (disjoint file sets, dependencies, scenario→module) + test contract (scenario→layer→file slots) — the single source of truth both develop and test derive from. Absent when the planner is skipped, which happens in either of two cases: (1) the issue's own description already predicts a single-module shape — a `## Files` section listing ≤3 code files, its Notes declaring `Dependencies: None`, and every scenario sharing one test-layer tag; or (2) a `trivial`/`minor` *baseline* diff (a small change on top of pre-existing work). Greenfield tasks always run the planner unless the single-module prediction check already fired first. |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `generated-tests.md` | test agent (generate mode) | test agent (execute mode) | one line per generated test file with its layer |
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

The canonical implementation of this capture and its unified-diff assertion is `src/hooks/capture-diff.sh`.

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

### `generated-tests.md` format

Written by the test agent when it runs in `Mode: generate` — one line per test file it created, tagged with the layer that produced it:

```markdown
# Generated Tests

- src/auth/auth.service.spec.ts (unit)
- src/auth/auth.controller.spec.ts (integration)
```

Header-only (no bullet items) means no test file was created in that run. The test agent reads this file back when invoked in `Mode: execute` to know which files to run, grouped by layer — it does not regenerate anything in that mode.

A test slot that collides with the denylist is never added here — the worker skips writing it and reports the conflict verbally to the caller instead, so the manifest only ever lists files that actually exist on disk.

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
  `stack.md`, `diff.md`, `spec.md`, `design.md`, and `pre-quality-snapshot.sha` before launching any agent.
  Also creates `phase-status.md` with the empty header row at pipeline start. The orchestrator
  **refreshes `diff.md` (and `diff-class.txt`) once more after the develop phase** — it is the
  only file rewritten mid-pipeline, and only by the orchestrator itself.
- **Planner** (`ship:plan`): sole writer of `plan.md`, before develop and test run. It is the
  one phase that produces (rather than only reads) a shared artifact other phases consume.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files
  (develop and test read `plan.md`). The only write allowed is **appending** rows to
  `phase-status.md` upon phase completion.
- **`analyze`**: read only from existing files, plus writes its own `drift-report.md` /
  `drift-findings.json` outputs (persisted per storage mode as part of its own dispatch in
  Phase 4) and appends rows to `phase-status.md`, same as the other phase agents.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed. In `Mode: generate` it instead writes `generated-tests.md`
  (never `test-failures.md`, since nothing ran); in `Mode: execute` it reads `generated-tests.md`
  back and writes `test-failures.md`. `generated-tests.md` follows the same "test agent writes,
  no agent deletes another's files" convention already stated below.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files (baseline `diff.md`) |
| After develop phase | Orchestrator refreshes `diff.md` + `diff-class.txt` over the post-develop working tree (authoritative) |
| During pipeline | Agents read and append as needed |
| `Mode: generate` run of `ship:test` | Writes `generated-tests.md` (does not write `test-failures.md`) |
| `Mode: execute` run of `ship:test` | Reads `generated-tests.md` (does not delete it) and writes `test-failures.md` |
| End of `/ship:pr` | Orchestrator removes `.context/ship-run/<task-id>/` (recursive) |
| `--keep-context` flag in `/ship:pr` | Directory is preserved for manual inspection |

The parent directory `.context/ship-run/` may hold multiple `<task-id>/` subdirs if
parallel pipelines are running — never remove the parent, only the completed task's subdir.

---

## Fan-out token optimization

When an orchestrator dispatches N sub-agents, each opens a fresh conversation with no shared prompt cache. Avoid making the orchestrator **re-emit** a large artifact it already holds — that pays the artifact's token cost once in the orchestrator's output for every child it inlines into. Two mechanisms, chosen by whether each child needs the whole artifact or only a slice:

**(a) Scratch-dir reference (whole artifact, unsliced).** When every child needs the full artifact (e.g. perf/security/review each analyze the full `diff.md`), the orchestrator writes it to the scratch dir **once** and passes only the **path**. Each child reads the file itself — same input cost as inline, but the orchestrator never re-emits the content. This is the default for the `diff` at the `ship:run` → phase dispatch level: the orchestrator does **not** inject `## Diff` inline; the phase agent reads `.context/ship-run/<task-id>/diff.md`.

**(b) Inline slicing (disjoint subsets).** When each child needs only a disjoint subset, the orchestrator reads the artifact **once**, slices it into per-agent subsets, and passes the slice **inline**. The smaller per-child input is the win here; children must not re-read the original file. This applies to the **inner** fan-outs listed in the table below (e.g. `ship:security` slicing the diff by OWASP category to its 3 sub-agents).

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
| `ship:develop` | `plan.md` module map (fallback: Design document) | by module / independent implementation unit |`)

## 4. Test-failure context (passthrough)

If `.context/ship-run/<task-id>/test-failures.md` exists, read it. If it lists any modules after the `# Test Failures` header, pass them through to the agent as a `## Test Failures` section so it prioritizes reviewing those modules. If the file contains only the header (zero failures) or does not exist, pass nothing.

## 5. Invoke ship-review agent

Use the Agent tool with `subagent_type: ship:ship-review`. Pass all context inline in the prompt:

```
Task: <task-id>
Artifact language: <artifact_language>
Scratch dir: .context/ship-run/<task-id>/
Storage mode: <linear|local>
Stack: <stack>

## Config
Severity Overrides: <severity-overrides or "none">

## Diff
<inline: full diff content>

## Test Failures
<inline: modules with failing tests, or omit if none>
```

The agent handles the full review, findings report, gate decision, and phase-status update. Return the agent's full output verbatim as your final message.
