---
name: ship:audit:run
description: "Ship Audit: meta-command that runs all applicable audits based on ship/config.md project type. Produces a consolidated report."
argument-hint: ""
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "haiku"
---

# Ship Audit — Run All

You are the Ship audit orchestrator. Your mission is to determine which audits apply to this project, launch them as parallel agents, and consolidate the results into a unified audit report with a single gate decision.

---

## Determine storage mode

See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

---

## Process

### 1. Load context

Read `ship/config.md` and extract:
- **Project Type** (backend | frontend | fullstack | monorepo)
- **Database** (MongoDB | PostgreSQL | MySQL | none)
- **Frontend** (Next.js | React | Vue | none | etc.)
- **Workspaces** (if monorepo)

### 2. Determine applicable audits

> **`audit:tests` is always included regardless of project type.**

Use this routing table:

| Project Type | Database configured? | Audits to run |
|---|---|---|
| `backend` | yes | audit:backend + audit:database + audit:security + audit:tests |
| `backend` | no | audit:backend + audit:security + audit:tests |
| `frontend` | — | audit:frontend + audit:security + audit:tests |
| `fullstack` | yes | audit:backend + audit:database + audit:frontend + audit:security + audit:tests |
| `fullstack` | no | audit:backend + audit:frontend + audit:security + audit:tests |
| `monorepo` | varies | See monorepo logic below + audit:tests |

**Monorepo logic:**
- Read the `Workspaces` section of `ship/config.md`
- For each workspace classified as `backend`: run `audit:backend` + `audit:security` for that workspace
- For each workspace classified as `frontend`: run `audit:frontend` for that workspace
- If any workspace has a database configured: run `audit:database`
- Always include one `audit:security` covering the full monorepo
- Always include one `audit:tests` covering the full monorepo

### 3. Announce the plan

Before launching agents, output:

```
Running Ship audit suite for <Project Type> project:
- audit:backend    [yes | no]
- audit:frontend   [yes | no]
- audit:database   [yes | no — <DB type>]
- audit:security   [yes]
- audit:tests      [yes]

Launching <N> audits in parallel...
```

### 4. Launch all applicable audits in parallel

Invoke each applicable audit skill via the **Skill tool** in **a SINGLE assistant turn** so they fork concurrently. Each audit skill declares `context: fork` + `model: "haiku"` in its frontmatter and delegates to its named `ship-audit-*` agent (which runs the heavy analysis on `sonnet`), so each runs in an isolated subagent automatically — do NOT wrap any of them in an `Agent` tool call.

- **`ship:audit:backend`**: returns the findings report from the full backend audit
- **`ship:audit:database`**: returns the findings report from the full database audit
- **`ship:audit:frontend`**: returns the findings report from the full frontend audit
- **`ship:audit:security`**: returns the findings report from the full security audit
- **`ship:audit:tests`**: returns the findings report from the full test coverage audit

Each agent writes its own report file:
- `ship/audits/backend-<YYYY-MM-DD>.md`
- `ship/audits/database-<YYYY-MM-DD>.md`
- `ship/audits/frontend-<YYYY-MM-DD>.md`
- `ship/audits/security-<YYYY-MM-DD>.md`
- `ship/audits/tests-<YYYY-MM-DD>.md`

### 5. Consolidate results

After all agents complete, each agent's tool result contains a JSON summary block (see # Audit Summary Schema

Each `ship:audit:*` agent must output this JSON block as the **very last content** of its tool result. `ship:audit:run` reads it directly from the agent result (already in context) — no file I/O needed.

## Schema

```json
{
  "audit": "<backend|frontend|database|security|tests>",
  "gate": "<PASS|WARN|FAIL>",
  "score": "<A|B|C|D|F>",
  "counts": {
    "critical": 0,
    "high": 0,
    "medium": 0,
    "low": 0
  },
  "top_findings": [
    {
      "id": "<FINDING-ID>",
      "severity": "<critical|high|medium|low>",
      "title": "<short title>",
      "file": "<path/to/file.ts:line>"
    }
  ],
  "report_path": "ship/audits/<type>-<YYYY-MM-DD>.md"
}
```

## Field definitions

| Field | Type | Description |
|-------|------|-------------|
| `audit` | string | Audit type identifier |
| `gate` | `PASS\|WARN\|FAIL` | Gate result per `# Gate Rules

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

## Snapshot pré-fix

> **No commits happen during the pipeline.** `ship:develop` and the auto-fix Agent write to the working tree; the first commit is created only in `ship:pr`. So HEAD does not advance, and any `git diff <sha> HEAD` is always empty. Re-run scoping must therefore compare working-tree snapshots, not commits.

Two distinct artifacts:

1. **`pre-quality-snapshot.sha`** — the HEAD SHA captured at step 0.5, before any quality agent starts. It is a baseline/diagnostic reference for the pre-quality HEAD. (It is **not** used to compute the fix diff — HEAD never moves — and the PR agent builds its diff directly from the working tree via `git diff`/`git status`.)

   - **File:** `.context/ship-run/<task-id>/pre-quality-snapshot.sha`
   - **Format:** single line containing the SHA from `git rev-parse HEAD`.

2. **`pre-fix-files.txt`** — a per-file content snapshot (`<hash> <path>` per changed file) captured **immediately before the auto-fix Agent runs**. After the fix, the orchestrator recomputes the same snapshot and diffs the two to determine exactly which files the fix touched (see *Re-run cirúrgico* below). This is what drives the `on_fail_rerun` scoping.

**Flag `on_fail_rerun`** (configured in `ship/config.md → Gate Behavior`):

| Value | Behavior |
|-------|----------|
| `surgical` *(default)* | After auto-fix is applied, re-run **only the phases that failed or warned**. Phases that already passed are skipped. |
| `all` | After auto-fix is applied, re-run **all quality phases** (perf, security, review) regardless of their previous result. |

> **Scope note:** M5.1 establishes the schema and snapshot capture step only. The actual re-run logic that reads `on_fail_rerun` and selects which phases to re-launch is implemented in M5.2.

## Re-run cirúrgico

After auto-fix is applied (on_fail: fix or on_warn: fix), the orchestrator selects which quality phases to re-run based on the `on_fail_rerun` config flag.

### Phase → scope mapping

| Phase | Scope | Rationale |
|-------|-------|-----------|
| `perf` | Files matching `src/**` or `lib/**`, excluding `*.test.*`, `*.spec.*`, `**/__tests__/**` | Performance issues are in hot paths, not test code |
| `security` | All files in the diff | Security scope is intentionally broad — any file could introduce a vulnerability |
| `review` | All files in the original diff | Review covers everything that changed |

### Algorithm (surgical mode)

1. Capture the pre-fix snapshot (`pre-fix-files.txt`) before the fix Agent runs
2. After the fix, recompute the snapshot (`post-fix-files.txt`) and `comm -13` the two to get the files the fix changed (working-tree comparison — **not** `git diff <sha> HEAD`, which is always empty since nothing is committed mid-pipeline). See `run.md` → Surgical Re-run Procedure for the exact commands.
3. For each phase that previously ran:
   - Compute intersection of (modified files) and (phase scope)
   - If intersection is non-empty → re-run phase
   - If intersection is empty → skip phase
4. Log decision (see format below)
5. Launch selected phases in parallel

Steps 2-3 (computing the modified-files intersection against each phase's scope and deciding whether to re-run) are implemented by the hook `src/hooks/rerun-scope.sh`, invoked via `@@ship/hooks/rerun-scope.sh` from `run/SKILL.md`. It takes the fix's changed-files list as input and applies the same scope rules from the *Phase → scope mapping* table above, returning JSON in the shape:

```json
{"phases":{"perf":{"rerun":true,"reason":"..."},"security":{"rerun":true,"reason":"..."},"review":{"rerun":false,"reason":"..."},"analyze":{"rerun":true,"reason":"..."}},"out_of_scope":false,"empty":false}
```

`run/SKILL.md`'s Surgical Re-run Procedure invokes this script directly and consumes its JSON output rather than computing the intersection in prose.

### Log format

```
Fix tocou: <file1>, <file2> (<N> arquivo(s))
Re-run cirúrgico: <phase1> (<reason>), <phase2> (<reason>)
Re-run pulado: <phase3> (não analisava arquivos modificados), <phase4> (não analisava arquivos modificados)
```

### Behavior with `on_fail_rerun: all`

When `on_fail_rerun: all`, skip the scope mapping entirely and re-run all quality phases that were originally enabled. This is the "safe" fallback — guaranteed to catch any regression introduced by the fix.

## Example: analyze phase in phase-status.md

`analyze` dispatches in the same Phase 4 parallel turn as `perf`/`security`/`review` and its findings feed the same single aggregated gate in Phase 5 (see `run/SKILL.md` → Phase 4/5) — it does not run a second gate cycle of its own. Its row in `phase-status.md` follows the identical run/timestamp/gate schema as the other three:

```markdown
| analyze | #1 | 2026-05-01T10:07:00Z | 5 | warn | 0 | 0 | 2 | 1 | 2 criterios sem testes |
| analyze | #2 | 2026-05-01T10:12:00Z | 5 | pass | 0 | 0 | 0 | 0 | re-run cirúrgico |
```

### analyze phase scope mapping (Surgical Re-run)

| Phase | Scope |
|-------|-------|
| `analyze` | All files in the original diff (broad scope — re-run if any file changed by fix) |

The analyze phase is always re-run after a fix because spec↔code correlation depends on the entire diff, not individual files.

## Re-run: edge cases

The following edge cases apply to both `on_fail: fix` and `on_warn: fix` paths. They are enforced inside the **Surgical Re-run Procedure** in `run.md`.

### Edge case 1 — Fix vazio (sem mudanças)

**Trigger:** the pre-fix vs post-fix snapshot comparison (`comm -13`) returns an empty file list after the fix agent runs.

**Behavior:**
- Skip all re-run phases (nothing changed, nothing to validate).
- Log: `⚠ Fix não produziu mudanças. Re-run ignorado.`
- For each phase that failed/warned: write a new row in `phase-status.md` with gate=`warn` and notes=`fix sem mudanças — revisão manual necessária`.
- Continue to acceptance with the warning visible.

### Edge case 2 — Loop de re-runs (máximo 3 iterações)

**Trigger:** `$FIX_ITERATION` counter exceeds 3 (i.e., the pipeline has already cycled through fix→re-run three times without resolving the gate).

**Behavior:**
- Abort the pipeline immediately.
- Inform the user: "Limite de 3 iterações fix→re-run atingido. Intervenção manual necessária."
- Do NOT proceed to acceptance — wait for user action.

### Edge case 3 — `on_warn: fix` usa lógica cirúrgica

**Trigger:** Gate returns exit code 1 (WARN) and `on_warn` is set to `fix`.

**Behavior:** Identical to `on_fail: fix` — apply the full Surgical Re-run Procedure including all edge cases (empty fix, iteration limit, out-of-scope files). No special handling for warnings vs failures.

### Edge case 4 — Fix tocou arquivo fora do scope original

**Trigger:** After the fix, the snapshot comparison returns a file that does not match any phase scope rule (not under `src/**`, `lib/**`, or any recognized path from the scope mapping table).

**Behavior:**
- Re-run ALL originally enabled quality phases (conservative mode — the fix touched unknown territory).
- Log: `Fix tocou arquivo(s) fora do scope original (<file>). Re-run conservador: todas as fases ativadas.`
- Do NOT apply surgical scoping — launch all phases in parallel as in Phase 4.` |
| `score` | `A–F` | Quality score (see scoring table below) |
| `counts` | object | Finding counts by severity |
| `top_findings` | array | Up to 5 most severe findings; empty array if none |
| `report_path` | string | Relative path to the full markdown report |

## Scoring table

| Score | Criteria |
|-------|----------|
| A | No findings, or only `low` findings |
| B | No `critical`/`high`; at least one `medium` |
| C | No `critical`; 1–2 `high` findings |
| D | No `critical`; 3+ `high` findings |
| F | At least one `critical` finding |

## Audit-specific notes

| Audit | Gate cap | Notes |
|-------|----------|-------|
| `backend` | PASS\|WARN\|FAIL | Standard gate |
| `frontend` | PASS\|WARN\|FAIL | Standard gate |
| `database` | PASS\|WARN\|FAIL | Standard gate |
| `security` | PASS\|WARN\|FAIL | Standard gate |
| `tests` | **PASS\|WARN** | HIGH findings map to WARN, not FAIL — test gaps are a quality issue, not blocking |

## Usage in `ship:audit:run`

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step.). Extract those summaries directly from the tool results — **do NOT re-read the markdown report files**.

Use the **Agent** tool to consolidate results. Pass `model: "haiku"` — this is template/report aggregation, not reasoning.

Pass the extracted JSON summaries **inline** in the consolidation agent's prompt. Instruct the agent to:
1. Use the provided JSON summaries (already included in the prompt — no file reads needed)
2. Evaluate the consolidated gate logic (see below)
3. Return the full consolidated summary report as its output

Step 6 writes the output to the correct path.

**Consolidated gate logic:**
- If ANY individual audit gate = **FAIL** → consolidated gate = **FAIL**
- If ANY individual audit gate = **WARN** (and none FAIL) → consolidated gate = **WARN**
- All **PASS** → consolidated gate = **PASS**

### 6. Write consolidated report

**Local mode:** Write to `ship/audits/run-<YYYY-MM-DD>.md`

**Linear mode:**
1. Create a Linear Document titled "Audit Suite — <YYYY-MM-DD>" with the consolidated report
2. Individual audit documents (backend, database, frontend, security, tests) were already created by each agent
3. Link all documents together in the consolidated report

**Consolidated report format:**

```markdown
# Ship Audit Suite — <YYYY-MM-DD>

## Gate Result

**PASS | WARN | FAIL**

## Summary by Audit

| Audit | Critical | High | Medium | Low | Gate |
|-------|----------|------|--------|-----|------|
| Backend Performance | X | X | X | X | PASS/WARN/FAIL |
| Database | X | X | X | X | PASS/WARN/FAIL |
| Frontend Performance | X | X | X | X | PASS/WARN/FAIL |
| Security | X | X | X | X | PASS/WARN/FAIL |
| Test Coverage | X | X | X | X | PASS/WARN/FAIL |
| **TOTAL** | **X** | **X** | **X** | **X** | **PASS/WARN/FAIL** |

## Critical and High Findings (All Audits)

[All critical and high findings from all audits, ordered by severity then audit type]

### [SEVERITY] <Finding Title> — <Audit Type>
- **Category:** ...
- **File:** ...
- **Description:** ...
- **Impact:** ...
- **Suggestion:** ...

## Unified Prioritized Roadmap

| Priority | Finding | Audit | Severity | Effort | Quick win? |
|----------|---------|-------|----------|--------|------------|

## Medium and Low Findings

[Summarized — refer to individual audit reports for full details]

| Finding | Audit | Severity | Effort |
|---------|-------|----------|--------|

## Individual Audit Reports

- Backend: `ship/audits/backend-<YYYY-MM-DD>.md`
- Database: `ship/audits/database-<YYYY-MM-DD>.md`
- Frontend: `ship/audits/frontend-<YYYY-MM-DD>.md`
- Security: `ship/audits/security-<YYYY-MM-DD>.md`
- Test Coverage: `ship/audits/tests-<YYYY-MM-DD>.md`
```

### 7. Present results to user

After writing the consolidated report:

1. Show the gate result: **PASS**, **WARN**, or **FAIL**
2. List all `critical` and `high` findings with their audit source
3. Show the unified roadmap
4. If gate = FAIL: "Pipeline is blocked. Resolve critical/high findings before proceeding."
5. If gate = WARN: "Medium findings detected. Review and decide whether to proceed."
6. If gate = PASS: "All audits passed. Codebase is in good shape."

---

## Rules

- **ALWAYS launch all applicable audits in a single parallel call** — never run audits sequentially.
- **Do not skip security**: `audit:security` always runs regardless of project type.
- **Do not skip tests**: `audit:tests` always runs regardless of project type — a failure in `audit:tests` does not block the other audits from running in parallel.
- **Monorepo**: scope each backend/frontend audit to the correct workspace directory; share the security audit across all workspaces.
- **Consolidated gate is pessimistic**: a single FAIL in any audit = overall FAIL.
- **Individual reports are authoritative**: the consolidated report summarizes; individual reports have full details.
- **Language**: See # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`..
- **For project-wide diff context**: after running `/ship:audit:run`, individual pipeline phases (`/ship:perf`, `/ship:security`) still run per-task during development. Audits are for periodic project-wide health checks.
