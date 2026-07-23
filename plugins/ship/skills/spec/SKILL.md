---
name: ship:spec
description: "Ship Spec: deep specification from a Linear issue or free prompt. Decomposes into granular tasks (<400 lines each), creates Linear project with documents, milestones, labels, and detailed issues. Without Linear, creates local markdown workspace."
argument-hint: "<linear-url | issue-id | free text description>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
user-invocable: true
model: "sonnet"
---

# Ship Spec — Specification & Task Decomposition

Turns a Linear issue or free text into a spec + granular tasks (<400 lines each). Linear: project + labeled issues. Local: mirrors under `ship/changes/<feature>/`.

**Input:** $ARGUMENTS

## Process

### 1. Detect input & storage mode

`linear.app` URL or `^[A-Z]+-\d+$` → Linear issue ID; else free text. See # Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`).

### 2. Gather context — yourself, sequentially (no agents)

**A (source):** Linear → # Load Artifacts

Matrix of artifact loading by context and storage mode:

| Context | Linear mode | Local mode |
|---------|------------|------------|
| **Spec** (`/ship:spec`) | `get_issue` + `list_comments` + linked documents | free text (no prior artifacts to load) |
| **Pipeline phase** (develop, perf, security, review) | `get_issue` + `get_document(Design)` + optionally `get_document(Proposal)` | `proposal.md` + `design.md` + `tasks.md` |
| **Orchestration** (run, homolog) | `get_issue` + `list_documents` → `get_document(Proposal)` + `get_document(Design)` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **PR** (`/ship:pr`) | `get_issue` + `get_document(Proposal, Design)` (via cache if available, else `list_documents`) + `list_comments` | `proposal.md` + `design.md` + `tasks.md` + `report.md` |
| **Audit** | `ship/config.md` only | `ship/config.md` only |

All contexts also read `ship/config.md` for stack and conventions.

**Pipeline phases only** (perf, security, review): after loading artifacts, run `git diff` to get the full diff of new/modified code — this is the primary analysis input. + `list_comments` → requirements/AC/constraints/motivation; free text → decompose, flag ambiguities.
**B (codebase):** `ship/config.md` + affected modules/patterns/deps, risk, scope, labels.

### 3. Clarify

`ship/config.md → ## Clarify → mode` (default `on`); `off` → skip to §4.

`on`:
1. Categories: `functional-scope`, `data-model`, `ux-flow`, `non-functional`, `integrations`, `edge-cases`, `tradeoffs`, `terminology`, `completion-signals`.
2. Rank Impact × Uncertainty (H/M/L, desc); ties → category order above.
3. Ask ≤5 one at a time, prose only: stem + 2-5 options (one `(recommended)`) + accept word/free-text/"unsure", in `Artifact language` (IDs/logic English).
4. Fold answers in immediately, re-rank remainder (zero ambiguity → skip); leftover → inline `[NEEDS CLARIFICATION: <category>: <topic>]` in Proposal/Design only; headless → auto-pick `(recommended)`, never block.

### 4. Deep specification

**Requirements:** `REQ-01…` (context, behavior, edge cases, constraints) + sequential testable `AC-01…` + area tag.

**Scenarios** — `ship/config.md → ## Scenario Depth → depth` (default `full`): `none`=no Scenarios; `light`=nominal+dominant error/AC; `full`=+key edge (`Outline`+`Examples` collapse combinatorics). Enabled → stable spec-global `@SC-XX`/Scenario, tagged `@AC-YY`+layer (`@unit`/`@integration`/`@e2e`), shared `Background:`, concrete not restated ACs, one `Feature`/task. Worked example: `${CLAUDE_SKILL_DIR}/patterns/gherkin-example.md`.

**Design:** architecture fit; decisions (choice, alternatives rejected+why); files+line estimate; data/API changes; risks.

### 5. Task decomposition

<400 lines incl. tests, independently buildable/testable, unambiguous scope, dependency-ordered. Estimate conservatively (e.g. service ~150-250, endpoint ~80-150 lines), split overages; assignment here feeds §6's `## Files`.

**Milestones:** delivery phases by dependency flow. **Labels:** Area (`backend`/`frontend`/`shared`/`infrastructure`/`database`) + Type (`feature`/`test`/`refactor`/`config`/`migration`) from `ship/config.md`.

### Gates (before creating any artifact)

- **Clarify markers** (skip if `mode` off): scan drafted Proposal/Design via `bash "${CLAUDE_SKILL_DIR}/hooks/needs-clarification-scan.sh" <dir>`: `2` (fail) → halt/resolve, headless downgrades to warn; `1` (warn) → confirm with user; `0` → proceed.
- **Spec quality:** audit REQ/AC for ambiguity (AMBIG), underspecification (SUBSPEC), convention violations (PRINCIPLE) via `${CLAUDE_SKILL_DIR}/patterns/spec-quality.md` — pre-filters + one batched sub-agent, strict JSON; apply rewrites first. Runs only here, once — never inside the pipeline (`/ship:run`).

## 6. Create artifacts

Linear: `save_project` (new, never reuse) → id in `ship/config.md ## Linear Project` → `artifact_language` → Proposal+Design docs → milestones → labels → issues (labeled, milestone-linked).
Local: `ship/changes/<feature>/{proposal,design,tasks}.md` (`## Milestone N`, `### TASK-NNN`) — same content.

- **Proposal:** Source, Why, Scope, Technical Context, Requirements per §4, plus Scenario Index (`SC-XX → AC-YY · layer · title`, omit if depth `none`).
- **Design:** per §4 (architecture, decisions, files+lines, data/API, risks), plus Sequence Diagrams (Mermaid) for complex flows.
- **Task/Issue:** Context (why+files) → What to do → `## Files` (`create|modify <path> — <intent>`; optional `Âncora: siga o padrão de <path> — <reason>`, real analogs only) → `AC-XX`+typecheck/tests → Scenarios (Gherkin/§4, omit if `none`) → Notes (deps).

**SC↔task cross-reference:** diff Scenario Index vs task Scenarios via `bash "${CLAUDE_SKILL_DIR}/hooks/sc-crossref.sh" --index <file> --issues <dir>`; fix violations, re-run until clean, before §7.

## 7. Present to the user

Summarize totals + task tree (per milestone/label, lines, files, project URL if Linear); ask if correct, apply fixes, then `/ship:run <issue-id|TASK-001>` or `--project <name>`.

## Rules

- <400 lines/task (Gherkin excluded), buildable/testable independently, unambiguous scope — non-negotiable; never fabricate requirements; `SC-XX` stable/spec-global, never renumbered.
- `## Files` = paths+intent+≤1 real-pattern anchor; union across tasks reproduces the Design's Files tables exactly.
- No leaked `[NEEDS CLARIFICATION]` markers or `REQ-`/`AC-`/`SC-` IDs in code/tests.
- Language: see # Artifact Language

- All user-facing text during execution (reports, summaries, gate results, status updates, questions) follows the `Artifact language` field from `ship/config.md → Conventions`
- Code, variable names, file paths, commit messages, branch names, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
- **Gherkin scenarios**: the natural-language step prose (`Given`/`When`/`Then` bodies, `Scenario`/`Feature` titles) is user-facing and follows the `Artifact language`. The Gherkin **keywords** (`Feature`, `Background`, `Scenario`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, `But`), the `@SC-XX`/`@AC-XX`/`@layer` tags, and the `TEST-*`/`IMPL-*` markers are technical identifiers — always English, never translated

## Resolving artifact language

If `Artifact language` is already injected inline in the current prompt (e.g., by the `ship:run` orchestrator or a skill wrapper), use that value directly — do not re-read `ship/config.md`.

Otherwise, read `Artifact language` from `ship/config.md → Conventions`..
