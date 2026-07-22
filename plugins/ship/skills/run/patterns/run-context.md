# Run Context — Shared Scratch Between Agents

Temporary scratch pattern used by the `/ship:run` orchestrator to share context
between phase agents (develop, test, perf, security, review, analyze). `develop`
dispatches alone (Phase 2). Verification then runs in two turns: **Turn A**
dispatches `ship:test Mode: generate` + `perf`/`security`/`review` concurrently
(all need only the diff), and **Turn B** runs `test-exec` ∥ `analyze` (both need
the generated tests). All quality phases feed a single aggregated gate in
Phase 5 — see `run/SKILL.md` → Phase 3-4/5.

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
| `spec.md` | orchestrator (run) — once, in step 1 | plan, develop, analyze | per-task slice of the spec: full issue description (Context, What to do, Files section if present, Acceptance Criteria, Scenarios, Notes) + full text of only the requirement sections (REQ-XX) from the Proposal covering this issue's acceptance criteria + a compact scope index (one line per remaining requirement in the feature not included in full, as `<req-id> — <title> — covered by <issue-id>` — the em-dash keeps each entry a list line rather than a heading, so `analyze` skips it) so later phases know what is out of scope without loading its full text. Written once so phases read it instead of receiving it re-inlined per dispatch |
| `design.md` | orchestrator (run) — once, in step 1 | plan, develop, analyze | full Design document. Written once; `develop` slices it per module when fanning out workers |
| `plan.md` | plan skill (`ship:plan`); or `develop` (minimal `## Test Contract` only, when the planner was skipped) | develop, test | module map (disjoint file sets, dependencies, scenario→module) + test contract (scenario→layer→file slots) — the single source of truth both develop and test derive from. When the planner is skipped, `develop` still writes the `## Test Contract` so `ship:test` keeps that single source instead of falling back to raw scenarios. Planner skipped in either of two cases: (1) the issue's own description already predicts a single-module shape — a `## Files` section listing ≤3 code files, its Notes declaring `Dependencies: None`, and every scenario sharing one test-layer tag; or (2) a `trivial`/`minor` *baseline* diff (a small change on top of pre-existing work). Greenfield tasks always run the planner unless the single-module prediction check already fired first. |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `generated-tests.md` | test agent (generate mode) | test agent (execute mode) | one line per generated test file with its layer |
| `phase-status.md` | orchestrator only (creates header; consolidates rows) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `phase-status-<phase>.md` | one phase agent each (`develop`, `test-generate`, `test`, `perf`, `security`, `review`, `analyze`) | orchestrator (consolidation only) | scratch row for that phase's most recent dispatch, using `#<RUN>` as a literal placeholder in the Run column — overwritten each dispatch, never appended to by any other agent |
| `pre-quality-snapshot.sha` | orchestrator (run) | — | baseline HEAD SHA before quality phases (diagnostic; nothing commits mid-pipeline, so HEAD does not move and the PR diff is built from the working tree) |
| `pre-fix-files.txt` / `post-fix-files.txt` | orchestrator (run) | orchestrator (re-run) | per-file content snapshots (`<hash> <path>`) taken before/after the auto-fix Agent — diffed to scope the surgical re-run |
| `jaccard.json` | analyze agent | analyze agent (re-run) | Jaccard similarity matrix cache — keyed by diff + spec SHA-256 hashes; reused when hashes match to avoid redundant computation |
| `iteration-fix.txt` / `iteration-test-fix.txt` | `pipeline.sh iter` | `pipeline.sh iter` | persisted loop counters, see gates.md Edge case 2 |

### Diff resolution (skill wrappers) {#diff-resolution}

Phase skills that consume the diff (`perf`, `security`, `review`, `analyze`) resolve it in the same order:

**If `$ARGUMENTS` already contains a `## Diff` section** (injected inline by the orchestrator), use it directly — skip file reads and git commands.

**Otherwise:**
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → run `git diff origin/main...HEAD` to obtain the diff (canonical range per this pattern)

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

The orchestrator writes it **twice**: a provisional baseline during init (run-init.sh, step 0.4–0.7, before any code exists) and an authoritative refresh after `ship:develop` (step 2.5). The refresh is required because `ship:develop` writes code to the working tree without committing — an init-only, HEAD-based diff would be empty and the quality phases would analyze nothing. Standalone invocations (no scratch dir) fall back to `git diff origin/main...HEAD`, where the work under analysis is already committed.

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

Rows are written **exclusively by the orchestrator** — never directly by a phase agent. This is deliberate: `perf`+`security`+`review`+`analyze` dispatch concurrently in Phase 4 (and again on each surgical re-run round). If those agents each did their own read-modify-write append against the same shared file, two concurrent writers can both read the file before either writes back, and the second write silently discards the first agent's row (lost update) — `homolog` then treats the missing row as an automatic FAIL (`homolog/SKILL.md` → phase-with-no-row rule) even though that phase actually passed.

To avoid this, each phase agent writes its own row to a **private per-phase scratch file** (`phase-status-<phase>.md` — see above) instead of touching the shared file. Only the orchestrator, which runs single-threaded and consolidates immediately after each phase (or concurrent-dispatch barrier) returns (end of Phase 2, end of Phase 4, end of each surgical re-run round), reads those per-phase files and appends their rows into the canonical `phase-status.md`, substituting the literal `#<RUN>` placeholder with the real run number it already tracks (`#1` for the first pass, `#<N>` for surgical re-run round N via `$FIX_ITERATION`). Re-run iterations appear as additional rows with incremented run numbers. Timestamps are ISO-8601 UTC.

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

### `phase-status-<phase>.md` format

Written by exactly one phase agent (`<phase>` is one of `develop`, `test-generate`, `test`, `perf`, `security`, `review`, `analyze`) — a single line, no header, overwritten (not appended) on every dispatch of that phase:

```markdown
| perf | #<RUN> | 2026-05-01T10:02:00Z | src/runner.ts | warn | 0 | 0 | 2 | 1 | N+1 query detected |
```

The orchestrator deletes (or ignores — it gets overwritten next dispatch) this file once it has consolidated the row into `phase-status.md`.

### `pre-quality-snapshot.sha` format

Single-line file with the commit SHA:

```
a1b2c3d4e5f6...
```

### `jaccard.json` format

Written and read by the deterministic correlation engine (`src/hooks/analyze-correlate.sh`) in pipeline mode only — it is the engine's full output, reused as a cache. Invalidated whenever `diff_hash` or `spec_hash` changes.

```json
{
  "diff_hash": "<sha256 of diff.md>",
  "spec_hash": "<sha256 of spec.md>",
  "test_scope": { "unit": "enabled", "integration": "disabled", "e2e": "disabled" },
  "truncated_tests": false,
  "truncated_spec": false,
  "requirements": [ { "id": "REQ-01", "description": "...", "confidence": 0.72, "file": "src/foo.ts" } ],
  "criteria":     [ { "id": "AC-01", "req": "REQ-01", "description": "...", "confidence": 0.9, "file": "test/foo.test.ts", "layer": "unit" } ],
  "scenarios":    [ { "id": "SC-01", "ac": "AC-01", "layer": "unit", "description": "...", "confidence": 0.9, "file": "test/foo.test.ts" } ],
  "disabled_layers": { "integration": ["AC-02", "SC-03"] },
  "orphans":      [ { "file": "src/zzz.ts", "confidence": 0 } ],
  "duplicates":   [ { "a": "REQ-03", "b": "REQ-04", "score": 0.83 } ],
  "summary": { "requirements": { "total": 4, "implemented": 2, "uncertain": 1, "unimplemented": 1 } }
}
```

- `diff_hash` and `spec_hash` are a compound cache key. On a hit, the engine returns this file verbatim without recomputing.
- `confidence` is the highest Jaccard score across candidate files; `file` is the best match (or `null`).
- Absent file means the run was standalone (no scratch dir passed) — no `jaccard.json` is written in that case.

---

## Read/write conventions

- **Orchestrator** (`run.md`): sole owner of **creating** the directory and **writing**
  `stack.md`, `diff.md`, `spec.md`, `design.md`, and `pre-quality-snapshot.sha` before launching any agent.
  Also creates `phase-status.md` with the empty header row at pipeline start, and is the **sole
  writer of `phase-status.md`** thereafter — it consolidates every row from the per-phase
  `phase-status-<phase>.md` scratch files (see above) immediately after each concurrent-dispatch
  barrier (end of Phase 2, end of Phase 4, end of each surgical re-run round). The orchestrator
  **refreshes `diff.md` (and `diff-class.txt`) once more after the develop phase** — it is the
  only file rewritten mid-pipeline, and only by the orchestrator itself.
- **Planner** (`ship:plan`): sole writer of `plan.md`, before develop and test run. It is the
  one phase that produces (rather than only reads) a shared artifact other phases consume.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files
  (develop and test read `plan.md`). The only write allowed is **writing (overwriting) its own
  row** to its private `.context/ship-run/<task-id>/phase-status-<phase>.md` upon phase
  completion — never a direct write to the shared `phase-status.md`, since multiple phase agents
  write concurrently in the same turn (Phase 4's perf/security/review/analyze fan-out) and a
  shared-file append from concurrent agents loses rows.
- **`analyze`**: read only from existing files, plus writes its own `drift-report.md` /
  `drift-findings.json` outputs (persisted per storage mode as part of its own dispatch in
  Phase 4) and writes its row to `phase-status-analyze.md`, same as the other phase agents.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed. In `Mode: generate` it instead writes `generated-tests.md`
  (never `test-failures.md`, since nothing ran); in `Mode: execute` it reads `generated-tests.md`
  back and writes `test-failures.md`. `generated-tests.md` follows the same "test agent writes,
  no agent deletes another's files" convention already stated below. `Mode: generate` runs only
  after `ship:develop` has completed; the denylist derived from `plan.md` still keeps its workers
  from touching develop-owned source files.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files (baseline `diff.md`) |
| After develop phase | Orchestrator refreshes `diff.md` + `diff-class.txt` over the post-develop working tree (authoritative) |
| After the evidence gate passes | `ship:test Mode: generate` runs (writes test files and `generated-tests.md`, never `test-failures.md`), then the deterministic test-exec step runs the suite. If the evidence gate fails, the pipeline stops before this step |
| During pipeline | Agents read and append as needed |
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
| `ship:develop` | `plan.md` module map (fallback: Design document) | by module / independent implementation unit |
