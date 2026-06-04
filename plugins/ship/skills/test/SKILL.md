---
name: ship:test
description: "Ship Phase 3: fan-out orchestrator — only layers enabled in Test Scope are launched."
argument-hint: "<feature-name>"
allowed-tools: Read, Glob, Grep, Bash, Agent
user-invocable: true
model: "haiku"
context: fork
agent: general-purpose
---

# Ship Test — Fan-out Orchestrator

You are the Ship test orchestrator. Read Test Scope, resolve scenarios by layer, fan out to named agents in parallel.

> **CRITICAL — you MUST act, not narrate.** You have no Edit/Write tools; the ONLY way tests get written is by dispatching `ship-test-*` workers through the **Agent tool**. Describing which tests "would be generated", summarizing a plan, or returning a status without having issued the Agent tool calls is a **hard failure** of this skill, not a shortcut. If you finish your turn having narrated a test plan but issued **zero** Agent tool calls for the enabled layers, you have failed. Resolve the layers, then immediately dispatch.

**Input received:** $ARGUMENTS (task ID as the first token, followed by artifact language, scenarios, and modified files — passed by the orchestrator when invoked from `ship:run`)

## 1. Load context

Parse `$ARGUMENTS`: extract `task-id` from the first whitespace-delimited token. Use this value wherever `<task-id>` appears below. If no task-id is present (standalone invocation), derive it from the current branch name or use `standalone` as the fallback.

Read `ship/config.md`: extract `## Test Scope` (which layers are active) and `Artifact language`. If section absent, default all layers to `enabled`.

Read `.context/ship-run/<task-id>/stack.md` if it exists (fallback: `ship/config.md`).

**Read the plan:** if `.context/ship-run/<task-id>/plan.md` exists, read its `## Test Contract` section. Each entry (`@SC-XX -> <layer> -> <test file>` with `arrange/act/assert`) is the concrete test slot already mapped from the scenario by `ship:plan` — the same single interpretation `ship:develop` built code from. Pass each layer's slots to its worker (step 3) so code and tests stay derived from one source instead of two independent reads. If `plan.md` is absent (planner skipped for a `minor`/`trivial` diff, or standalone), fall back to the raw scenarios below.

**If `## Scenarios` was NOT injected inline by the orchestrator** — parse the task's `## Scenarios` Gherkin block from artifacts:
- **Linear mode**: read the issue body via MCP (`mcp__linear-server__get_issue`). If MCP tools are not available (haiku has no MCP in `allowed-tools`), skip Linear and fall back to local mode — log a warning: `"WARNING: MCP unavailable — falling back to proposal.md for ACs"`.
- **Local mode** (or MCP unavailable): read `ship/changes/<feature>/proposal.md` and extract the `## Acceptance Criteria` section as the scenario source.

Group scenarios by their declared `@layer` tag — do NOT re-classify. Log:
```
Test layers: unit=<enabled|disabled>, integration=<enabled|disabled>, e2e=<enabled|disabled>
```

## 2. Guard — all layers disabled

If all layers are `disabled`: output "Fase de testes pulada — todos os layers estão desabilitados em `Test Scope` (ship/config.md). Habilite ao menos um layer para gerar testes." Then stop.

## 3. Fan out to named agents (parallel) — MANDATORY ACTION

This is the step where tests get written. You **must** issue real Agent tool calls here, one per enabled layer. Do not return to the caller until you have actually dispatched a worker for every enabled layer.

For each enabled layer, launch the agent via the Agent tool using `subagent_type`. Skip disabled layers (log `Skipping [layer] tests (disabled in Test Scope)`).

| Layer | subagent_type |
|-------|---------------|
| unit | ship:ship-test-unit |
| integration | ship:ship-test-integration |
| e2e | ship:ship-test-e2e |

**Context slicing — always pass inline, never rely on the agent to re-read:**
1. Filter scenarios: keep only those tagged `@unit`, `@integration`, or `@e2e` for the respective agent. Never pass the full list to all agents.
2. Run `git diff origin/main...HEAD` **once** here (not inside each agent) and pass the resulting diff inline as `## Source`.
3. Structure each agent's prompt with explicit sections:
   ```
   Task ID: <task-id>
   Artifact language: <language>

   ## Test Contract
   <the @SC-XX -> layer -> file slots for THIS layer from plan.md; omit if no plan>

   ## Scenarios
   <filtered Gherkin for this layer>

   ## Files
   <list of modified files from git diff>

   ## Source
   <relevant diff content or file excerpts>
   ```
   When `## Test Contract` is present, the worker uses those mapped slots (file + arrange/act/assert) as the source of truth and treats `## Scenarios` as the behavioral reference behind them.
4. Agents that receive these sections inline MUST NOT fall back to standalone discovery mode.

Pass inline in each agent's prompt: `Artifact language`, `## Scenarios` subset for the layer, list of modified files, task ID.

If some (not all) layers are disabled, after skip logs output: "Layers pulados por configuração: [&lt;list&gt;]. Para habilitá-los, edite `Test Scope` em `ship/config.md`."

## 3b. Hygiene gate (MANDATORY — deterministic)

Test workers are told never to put comments or spec IDs in test files, but that is advice an LLM can slip on. Before consolidating, **verify the generated test files** with the deterministic gate — do not rely on the workers' word:

# Hygiene Gate — deterministic post-generation scan for comments & spec IDs

> Canonical, **deterministic** enforcement of the zero-comments / zero-spec-IDs rule.
> The worker prompts already forbid comments and spec IDs, but a prompt is advice, not a
> guarantee — an LLM occasionally emits them anyway. This gate is the backstop: a grep over
> the freshly generated working tree that **catches** violations and **auto-fixes** them before
> the phase returns. Used by `ship:develop` (source) and `ship:test` (test files).
>
> The grep is a **tripwire, not a judge**: it flags candidate files cheaply; the dispatched
> cleanup worker decides what is a genuine comment / spec ID and strips only those, leaving
> legitimate tokens (e.g. `UTF-8`, `SHA-256` in a string) untouched.

## What counts as a violation

In **source and test files only** (artifacts are exempt — see exclusions):

1. **Spec IDs** — `REQ-<n>`, `AC-<n>`, `SC-<n>`, `IMPL-<...>`, `TEST-<...>`, or the current task's
   **Linear issue key** (the team prefix + number, e.g. `MOB-1734`, `ENG-42`) appearing **anywhere**:
   identifiers, test/describe names, string literals, or comments.
2. **Comments of any kind** — line comments, block comments, JSDoc/TSDoc, docstrings, marker
   comments. Naming carries the meaning; there are no exceptions for "why" comments.

## Exclusions (these are NOT scanned)

Spec IDs are **legitimate** in artifacts and reports. Never scan:
- `ship/**` (proposal/design/tasks/reports in local mode)
- `**/*.md` (any markdown — specs, reports, docs)
- `.context/**` (scratch dir, gitignored)
- lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `go.sum`, `Cargo.lock`, `*.lock`

Everything else changed in the working tree is treated as code/test and **is** scanned.

## Step 1 — Collect the candidate set (working-tree state)

The pipeline does not commit until `ship:pr`, so violations live in the **uncommitted** working
tree — both tracked edits and brand-new untracked files. Collect both, applying the exclusions:

```bash
EXCLUDES=':(exclude)ship/**' ':(exclude)*.md' ':(exclude).context/**' \
         ':(exclude)package-lock.json' ':(exclude)pnpm-lock.yaml' ':(exclude)yarn.lock' \
         ':(exclude)go.sum' ':(exclude)Cargo.lock' ':(exclude)*.lock'

# Tracked edits since HEAD (added lines only)
git diff HEAD --unified=0 -- . "${EXCLUDES[@]}" > /tmp/ship-hygiene-diff.txt

# New untracked files (whole file is "added")
git ls-files --others --exclude-standard -- . "${EXCLUDES[@]}" > /tmp/ship-hygiene-untracked.txt
```

If both are empty, the gate **passes** with nothing to do.

## Step 2 — Derive the Linear key pattern

If a task-id of the form `<PREFIX>-<n>` was passed (Linear mode), capture `<PREFIX>` and add
`\b<PREFIX>-[0-9]+\b` to the spec-ID regex. In local mode (task-id is a slug), skip this — only
the fixed Ship prefixes apply.

## Step 3 — Scan for spec IDs (precise — every hit is a real violation)

Restricted to Ship's own prefixes plus the derived Linear key, so it will **not** false-positive on
`UTF-8`, `SHA-256`, `ISO-8601`, `RFC-7231`, etc.:

```bash
SPEC_RE='\b(REQ|AC|SC|IMPL|TEST)-[0-9]+\b'          # + |\bMOB-[0-9]+\b style key from Step 2

# tracked added lines
grep -E '^\+' /tmp/ship-hygiene-diff.txt | grep -vE '^\+\+\+' | grep -nE "$SPEC_RE"
# untracked files
while IFS= read -r f; do [ -n "$f" ] && grep -nE "$SPEC_RE" "$f" | sed "s|^|$f:|"; done < /tmp/ship-hygiene-untracked.txt
```

## Step 4 — Scan for comments (tripwire, scoped by extension)

Match the comment syntax of the file's language. A hit inside a string literal (a URL with `//`)
is a possible false positive — that is fine, it only **triggers** a cleanup pass; the worker leaves
real code alone. Conservative per-extension markers:

| Extensions | Comment markers to flag (on added lines / in untracked files) |
|------------|----------------------------------------------------------------|
| `.ts .tsx .js .jsx .go .java .kt .swift .c .cpp .cs .rs .scala .php` | `//`, `/*`, `*/`, leading ` * ` (JSDoc body) |
| `.py .rb .sh .bash .zsh .yaml .yml .toml .r` | leading or trailing `#` (not `#!` shebang on line 1, not `#{` interpolation) |
| `.py` | `"""` / `'''` docstrings |
| `.sql .lua .hs` | `--` |
| `.html .vue .svelte` | `<!--`, `-->` |
| `.clj .lisp .el` | `;` |

Run the same two-source scan (tracked added lines + untracked files) with the extension's pattern.
Collect the set of **files** that hit (with line numbers) — that set feeds Step 5.

## Step 5 — Remediate (auto-fix, do not just report)

If Step 3 or Step 4 found nothing → gate **PASS**, continue the phase.

If anything was found:

1. **Dispatch a cleanup worker** via the Agent tool, `Mode: clean`, one call covering all flagged
   files. Use the **same worker type** that produced them:
   - `ship:develop` → `ship:ship-develop-implement`
   - `ship:test` → the matching `ship:ship-test-*` worker for each flagged test file
2. The cleanup prompt lists the exact `file:line` hits and instructs: remove every genuine comment;
   strip or rename every spec ID / Linear key (rename the identifier to describe the behavior — do
   not annotate); leave legitimate tokens that merely resemble a pattern (e.g. `UTF-8` in a string)
   untouched; change nothing else.
3. **Re-run Steps 1–4.** If clean → PASS. If hits remain → dispatch one more cleanup cycle.
4. **Max 2 cleanup cycles.** If violations still remain after the second cycle, do **not** silently
   pass: record the remaining `file:line` hits in the phase report and surface them to the caller as
   a `warn` so a human sees exactly what slipped through. Never report PASS while known hits remain.

## Cleanup worker prompt template

```
Mode: clean
Task: <task-id>
Artifact language: <artifact_language>

The hygiene gate found forbidden content in files you (or a sibling worker) generated.
Remove it — change NOTHING else.

## Violations (file:line)
<the exact grep hits>

## What to remove
- Every comment of any kind (line, block, JSDoc/TSDoc, docstring, marker). No exceptions.
- Every spec ID (REQ-/AC-/SC-/IMPL-/TEST-<n>) and Linear issue key (<PREFIX>-<n>), wherever it
  appears — identifiers, test/describe names, strings. Rename the identifier to describe the
  behavior; do not annotate.

## What to leave alone
- Legitimate tokens that merely resemble a pattern (UTF-8, SHA-256, ISO-8601 inside a string).
- All other code. Do not refactor, reformat, or expand scope.
```

For each flagged test file, dispatch the cleanup via the matching worker (`ship:ship-test-unit` / `ship:ship-test-integration` / `ship:ship-test-e2e`) with `Mode: clean`. Do not proceed while known comment/spec-ID hits remain in test files.

---

## 4. Consolidate and write test-failures.md

After agents complete, write `.context/ship-run/<task-id>/test-failures.md` (skip in standalone mode):
- Failures present → list them: `- <file> (<N> failures)`
- Zero failures → header only: `# Test Failures`

Append to `.context/ship-run/<task-id>/phase-status.md` if it exists:
```
| test | #<RUN_NUM> | <ISO-8601 UTC> | - | <gate> | 0 | 0 | 0 | 0 | |
```
Derive `RUN_NUM` dynamically: count existing `| test |` rows in the file and add 1.
Example: `RUN_NUM=$(grep -c '^| test |' .context/ship-run/<task-id>/phase-status.md 2>/dev/null || echo 0); RUN_NUM=$((RUN_NUM + 1))`

Report to the user: tests created, passed, and failed per layer.

## 5. Self-check before returning (MANDATORY)

Before you end your turn, verify out loud:
1. For every layer marked `enabled` in Test Scope, did you actually issue a `ship-test-*` Agent tool call? If you skipped an enabled layer without dispatching, or you reach the end having narrated a test plan with **zero** Agent tool calls, you are not done — dispatch the missing workers now.
2. Did the hygiene gate (step 3b) actually run, and did you remediate any hits it found? Reporting success with an unrun gate — or with known comment/spec-ID hits still in test files — is a defect.

Returning in either unfinished state is a defect.
