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

`linear.app` URL or `^[A-Z]+-\d+$` → Linear issue ID; else free text. See @ship/patterns/storage-mode.md.

### 2. Gather context — 2 parallel agents

**A (source):** Linear → @ship/patterns/load-artifacts.md + `list_comments` → requirements/AC/constraints/motivation; free text → decompose, flag ambiguities.
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

**Scenarios** — `ship/config.md → ## Scenario Depth → depth` (default `full`): `none`=no Scenarios; `light`=nominal+dominant error/AC; `full`=+key edge (`Outline`+`Examples` collapse combinatorics). Enabled → stable spec-global `@SC-XX`/Scenario, tagged `@AC-YY`+layer (`@unit`/`@integration`/`@e2e`), shared `Background:`, concrete not restated ACs, one `Feature`/task. Worked example: `@@ship/patterns/gherkin-example.md`.

**Design:** architecture fit; decisions (choice, alternatives rejected+why); files+line estimate; data/API changes; risks.

### 5. Task decomposition

<400 lines incl. tests, independently buildable/testable, unambiguous scope, dependency-ordered. Estimate conservatively (e.g. service ~150-250, endpoint ~80-150 lines), split overages; assignment here feeds §6's `## Files`.

**Milestones:** delivery phases by dependency flow. **Labels:** Area (`backend`/`frontend`/`shared`/`infrastructure`/`database`) + Type (`feature`/`test`/`refactor`/`config`/`migration`) from `ship/config.md`.

### Gates (before creating any artifact)

- **Clarify markers** (skip if `mode` off): scan drafted Proposal/Design via `bash "@@ship/hooks/needs-clarification-scan.sh" <dir>`: `2` (fail) → halt/resolve, headless downgrades to warn; `1` (warn) → confirm with user; `0` → proceed.
- **Spec quality:** audit REQ/AC for ambiguity (AMBIG), underspecification (SUBSPEC), convention violations (PRINCIPLE) via `@@ship/patterns/spec-quality.md` — pre-filters + one batched sub-agent, strict JSON; apply rewrites first. Runs only here, once — never inside the pipeline (`/ship:run`/`/ship:analyze`).

## 6. Create artifacts

Linear: `save_project` (new, never reuse) → id in `ship/config.md ## Linear Project` → `artifact_language` → Proposal+Design docs → milestones → labels → issues (labeled, milestone-linked).
Local: `ship/changes/<feature>/{proposal,design,tasks}.md` (`## Milestone N`, `### TASK-NNN`) — same content.

- **Proposal:** Source, Why, Scope, Technical Context, Requirements per §4, plus Scenario Index (`SC-XX → AC-YY · layer · title`, omit if depth `none`).
- **Design:** per §4 (architecture, decisions, files+lines, data/API, risks), plus Sequence Diagrams (Mermaid) for complex flows.
- **Task/Issue:** Context (why+files) → What to do → `## Files` (`create|modify <path> — <intent>`; optional `Âncora: siga o padrão de <path> — <reason>`, real analogs only) → `AC-XX`+typecheck/tests → Scenarios (Gherkin/§4, omit if `none`) → Notes (deps).

**SC↔task cross-reference:** diff Scenario Index vs task Scenarios via `bash "@@ship/hooks/sc-crossref.sh" --index <file> --issues <dir>`; fix violations, re-run until clean, before §7.

## 7. Present to the user

Summarize totals + task tree (per milestone/label, lines, files, project URL if Linear); ask if correct, apply fixes, then `/ship:run <issue-id|TASK-001>` or `--project <name>`.

## Rules

- <400 lines/task (Gherkin excluded), buildable/testable independently, unambiguous scope — non-negotiable; never fabricate requirements; `SC-XX` stable/spec-global, never renumbered.
- `## Files` = paths+intent+≤1 real-pattern anchor; union across tasks reproduces the Design's Files tables exactly.
- No leaked `[NEEDS CLARIFICATION]` markers or `REQ-`/`AC-`/`SC-` IDs in code/tests.
- Language: see @ship/patterns/language.md.
