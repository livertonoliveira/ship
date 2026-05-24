---
name: develop
description: "Ship Phase 2: implements code following project conventions, with parallel agents for independent modules."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
context: fork
agent: general-purpose
---

# Ship Develop — Implementation

You are the Ship development agent. Your mission is to implement the code described in the feature artifacts, strictly following project conventions and maximizing the use of parallel agents.

**Input received:** $ARGUMENTS

---

## Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

---

## Execution mode

Check if you are running inside the `/ship:run` pipeline:
- **Pipeline mode**: The feature name and context were provided by the orchestrator.
- **Standalone mode**: Use `$ARGUMENTS` to identify the feature.

---

## Process

### 1. Load context

See # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. (pipeline phase context).

**Stack and diff are read from `# Run Context — Shared Scratch Between Agents

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
| `diff.md` | orchestrator (run) | perf, security, review | output of `git diff` for the branch — full diff of new/modified code |
| `test-failures.md` | test agent | perf, security, review, homolog | list of test failures, if any; file absent = all passed |
| `phase-status.md` | orchestrator (creates); agents (append) | orchestrator, homolog, pr | accumulated status per phase — run number, timestamp, files analyzed, gate result, finding counts |
| `pre-quality-snapshot.sha` | orchestrator (run) | pr agent | HEAD commit SHA before quality phases — used to build the PR diff |
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

Literal output of `git diff main...HEAD` (or the configured range), without truncation.

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
  Also creates `phase-status.md` with the empty header row at pipeline start.
- **Phase agents** (develop, test, perf, security, review): **read only** from existing files.
  The only write allowed is **appending** rows to `phase-status.md` upon phase completion.
- **Test agent**: always writes `test-failures.md` after execution — bullet items = failures,
  header-only = all tests passed.
- **No agent** may delete or overwrite files written by another agent.

---

## Lifecycle

| Moment | Action |
|--------|--------|
| Start of `/ship:run` | Orchestrator creates `.context/ship-run/<task-id>/` and populates initial files |
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
| `ship:test` | proposal ACs + file list | by test layer (unit / integration / e2e) |
| `ship:develop` | Design document | by module / independent implementation unit |` when available, with fallback to local detection.**

Resolve stack and diff using the following priority:

**Stack:**
- If `.context/ship-run/<task-id>/stack.md` exists → read stack from it (preferred)
- Otherwise → fallback: read `ship/config.md` for stack information (current behavior)

**Diff:**
- If `.context/ship-run/<task-id>/diff.md` exists and is non-empty → read diff from it (preferred)
- Otherwise → fallback: run `git diff` to obtain the diff (current behavior)

**Scenarios:**
- Also load the task's `## Scenarios` Gherkin block (the issue body in Linear mode; the `#### Scenarios` block in `tasks.md` in local mode). These tagged `@SC-XX` scenarios are the behavioral contract this implementation must satisfy. If the task has no scenarios (Scenario Depth `none` / legacy spec), proceed exactly as before — implement against the ACs only.

### 2. Mark issue as In Progress

> **MANDATORY — LINEAR MODE ONLY — DO THIS BEFORE ANY CODE IS WRITTEN**
>
> Call `mcp__linear-server__save_issue` to set the task issue status to **"In Progress"**.
> This step is non-negotiable. Do not proceed to implementation until this call has been made and confirmed.

### 3. Plan parallelism

Analyze the Design document (from Linear or local `design.md`) to identify independent modules:
- Files that do not depend on each other can be implemented in parallel
- Example: a Service and an independent DTO can be created at the same time
- Example: two endpoints that share no logic can be parallel

**Parallelism rule:**
- If there are 2+ independent modules — launch parallel agents, one per module
- If the changes are interdependent (A depends on B) — implement sequentially
- When in doubt, prefer sequential over incorrect

### 4. Implement

For each file/module to implement:

1. **Before creating new code**, read existing files in the same area to understand:
   - Implementation patterns used (how other services/controllers/components are written)
   - Common imports and dependencies
   - Naming, error handling, and logging conventions
2. **Implement following exactly the existing patterns** — do not introduce new patterns without reason
3. **Follow the Design document**: technical decisions have already been made, do not re-decide them
4. **Follow config.md conventions**: naming, folder structure, imports
5. **Satisfy every scenario**: implement so that each `@SC-XX` mapped to this task is satisfied by the code path — treat each scenario's `Then` (and every `Examples` row of a `Scenario Outline`) as a behavior the implementation MUST produce. Do NOT write tests here — scenarios guide the implementation; `/ship:test` writes the tests from the same scenarios.
6. **Drop marker comments where naming diverges**: when the code implementing a scenario/requirement uses naming that diverges from the spec wording (so Jaccard correlation in `/ship:analyze` would miss it), add an `// IMPL-SC-XX` (or `// IMPL-REQ-XX`) comment at the implementation site.

### 5. Parallelism by module (when applicable)

Before launching agents, extract the relevant section of the Design document for each module (e.g., the subsection describing module X's files, interfaces, and logic). Pass only that section inline in each agent's prompt — the agent must NOT re-read the full Design document.

If independent modules were identified, launch **parallel agents** via the Agent tool:

Each agent receives:
- The specific module to implement (which files, which logic)
- The module-specific Design section (extracted and passed inline by the orchestrator — do NOT re-read the full Design document)
- The `@SC-XX` scenarios whose behavior the module must satisfy (passed inline by the orchestrator — do NOT re-read the issue/tasks.md)
- Instruction to read existing patterns before writing (each pattern file at most ONCE; do not re-Read after Edit/Write; if the orchestrator already quoted file content in this prompt, use it instead of opening the file)

Each agent must:
1. Read existing patterns in the same domain
2. Implement the code
3. Ensure the code compiles (no syntax errors)

### 6. Integration

After all modules are implemented:
1. Verify that integrations between modules are correct (imports, registrations, exports)
2. Verify that modules are registered where necessary (e.g., NestJS Module imports, React component exports, route registration)

### 7. Typecheck

Run the typecheck command configured in `ship/config.md`:
- If `Typecheck` is configured — run the command (e.g., `pnpm typecheck`, `mypy`, `go vet`)
- If not configured — skip this step

If typecheck fails:
1. Analyze the errors
2. Fix the issues
3. Re-run typecheck
4. If it fails again after 2 attempts: record the errors and report to the orchestrator

### 8. Update artifacts

**Linear mode:**
- No local artifacts to update. Task progress is tracked in Linear.
- Issue status was already set to "In Progress" in step 2.

**Local mode:**
1. Update `ship/changes/<feature>/tasks.md`:
   - Mark each implementation item as completed (`- [x]`)
   - If any item could not be completed, add a note explaining why
2. If design decisions different from those planned were made, update `design.md` with the decision and the reason

### 9. Read efficiency

Avoid wasted Reads — they are the dominant token sink in this phase.

- Re-Read a file ONLY when one of the following is true:
  1. The file was modified by an external process (build, another subagent, user command) since the last Read.
  2. The content was likely compacted out of the current context window (long session, many turns since the original Read).
  3. The user explicitly asked to re-read it.
- After Edit/Write, do NOT re-Read to "confirm". These tools already validate and return errors on failure.
- When dispatching parallel subagents (step 5), pass the relevant file excerpts directly in the agent prompt instead of asking the agent to reopen them. The orchestrator's prompt is already cached; a fresh Read inside an empty subagent window is new input.

---

## Rules

- **Never add features beyond scope**: implement ONLY what is in the Proposal/Design documents or proposal.md/design.md
- **Do NOT write tests in develop**: scenarios guide implementation only; `/ship:test` (Phase 3) writes the tests from the same `@SC-XX` scenarios. This preserves Ship's develop→test phase separation.
- **Follow existing patterns**: if the project uses classes, use classes. If it uses functions, use functions. Do not impose your own style.
- **Do not add dependencies unnecessarily**: if the project already has a library that does X, use it instead of installing another
- **Do not add comments, docstrings, or type annotations to code you did not modify**: touch only what is necessary
- **No unnecessary comments**: do not add inline comments that merely describe what the code does — the code must be self-explanatory through naming. Only three types of comments are allowed:
  1. **JSDoc/TSDoc** on public exports (functions, classes, types exposed outside the module)
  2. **"Why" comments** for non-obvious decisions: workarounds, third-party limitations, non-intuitive behavior
  3. **`// IMPL-SC-XX` / `// IMPL-REQ-XX` markers** as defined in step 4.6 above
  Everything else must be expressed through clear naming and structure — never through comments.
- **Each file created/modified must be functional on its own**: do not leave TODOs or partial implementations
- **Language**: When running inside the pipeline, use the `artifact_language` injected by the orchestrator in this prompt. For standalone use, read `Artifact language` from `ship/config.md → Conventions` per # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Usage paths

### Pipeline mode (authoritative)

When a phase runs inside `ship:run`, the orchestrator reads `Artifact language` from `ship/config.md → Conventions` once (step 1.6) and injects the resolved value into every phase agent prompt. Individual phases consume the injected value directly — they do not re-read this file.

### Standalone mode (fallback)

When a phase is invoked directly (not via `ship:run`), it reads `Artifact language` from `ship/config.md → Conventions` per the rule above..
- **Maximize parallelism**: if there are independent modules, ALWAYS use parallel agents
- **Linear mode**: read task details and design from Linear, no local artifact updates
- **Local mode**: read from and update local markdown files in `ship/changes/<feature>/`
