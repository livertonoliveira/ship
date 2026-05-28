<p align="center">
  <img src="https://raw.githubusercontent.com/livertonoliveira/ship/main/docs/assets/logo.png" alt="Ship" height="96">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-Slash_Commands-7C3AED?style=for-the-badge" alt="Claude Code">
  <img src="https://img.shields.io/badge/Stack-Agnostic-10B981?style=for-the-badge" alt="Stack Agnostic">
  <img src="https://img.shields.io/badge/Zero_Dependencies-FF6B35?style=for-the-badge" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/Linear-Integration-5E6AD2?style=for-the-badge&logo=linear&logoColor=white" alt="Linear Integration">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT License">
</p>

<p align="center">
  <a href="README.pt-BR.md">Português</a> · English
</p>

---

<p align="center">
  <strong>Ship — From idea to Pull Request, with a single command.</strong><br>
  Specify, implement, test, audit, and ship — without coordinating anything manually.
</p>

<p align="center">
  <a href="#the-problem">The Problem</a> ·
  <a href="#the-solution">The Solution</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#configuration">Configuration</a>
</p>

---

## The Problem

You have an idea. You want to implement a feature. With Claude Code, the code comes out fast — but then the tedious part begins:

- Write the requirements somewhere
- Break them into tasks somewhere else
- Generate the tests (and remember to cover edge cases)
- Check for security vulnerabilities
- Analyze whether it'll be slow in production
- Review whether the code follows the project's standards
- Create a Pull Request with a decent description
- Update the task tracker

Each of these steps happens in a different tab, a different prompt, and a lot of context gets lost along the way. If the session crashes mid-pipeline, you start over.

---

## The Solution

Ship is a set of commands for Claude Code that automates this entire flow.

You describe what you want. Ship breaks it into tasks, implements it, tests it, reviews security and performance, and delivers a Pull Request with everything documented — with agents running in parallel at each step.

```bash
/ship:spec "add password reset"   # → creates project, milestones, and tasks
/ship:run TASK-42                  # → implements, tests, reviews, audits
/ship:pr                           # → Pull Request with quality report
```

That's the complete flow. Each command handles one step; you only intervene when something needs your attention.

### Before vs. After

| Without Ship | With Ship |
|---|---|
| Feature planning in free-form chat | Structured project with granular tasks and acceptance criteria |
| "Please review this" | 3 parallel agents: performance + security + code quality |
| Tests written on the spot, without criteria | Scenarios defined at spec time, generated automatically in tests |
| Manual OWASP eyeballing | Automated security scan on every delivery, with a blocking gate |
| "Initial commit" repeated 20 times | Atomic, standardized commits by design |
| Session crashes and context is lost | Artifacts persisted in Linear or local files |

---

## Installation

Ship is a Claude Code plugin. Install it from the marketplace:

```bash
claude plugin marketplace add livertonoliveira/ship
claude plugin install ship
```

That's it. No Node.js, no database, no other binary required. Ship is purely a set of commands that instruct Claude Code — the only requirement is having Claude Code installed.

### Updating

```bash
claude plugin update ship@ship-marketplace
```

Restart Claude Code after updating.

> **Note:** `claude plugin update ship` (without the suffix) fails with "Plugin not found". Always use the full name `ship@ship-marketplace`.

---

## Quick Start

```bash
# 1. Initialize Ship in your project (do this once per project)
/ship:init

# 2. Describe the feature you want to implement
/ship:spec "add email notifications for order status changes"

# 3. Run the full pipeline for a task created by spec
/ship:run MOB-42

# 4. Create the Pull Request with organized commits and a quality report
/ship:pr
```

`/ship:init` automatically detects your project's stack and configures everything. `/ship:spec` creates a structured project with tasks small enough to fit in a single session. `/ship:run` executes all quality steps for that task. `/ship:pr` packages everything into a clean Pull Request.

> **Shortcut:** if you already have a task in Linear — or want to implement something without going through spec — you can go straight to `/ship:run`. Spec is not a prerequisite; it just enriches the pipeline with predefined acceptance criteria and test scenarios.

---

## Commands

Ship has two groups of commands with distinct purposes.

### Pipeline — for day-to-day development

These commands are part of the normal delivery flow. Each one analyzes only **what was changed** in the current task.

| Command | What it does |
|---------|--------------|
| `/ship:init` | Initializes Ship in the project — detects stack, conventions, configures Linear, creates `ship/config.md` |
| `/ship:spec` | Decomposes a feature into granular tasks, defines test scenarios per acceptance criterion, creates a Linear project with milestones and issues |
| `/ship:run` | Runs the full pipeline for a task: implement → test → performance → security → review → homologation |
| `/ship:develop` | Implements code following project conventions (can run standalone or inside `/ship:run`) |
| `/ship:test` | Generates and runs unit, integration, and e2e tests based on scenarios defined at spec time |
| `/ship:perf` | Analyzes diff performance — detects project type and adapts agents accordingly |
| `/ship:security` | OWASP security scan of the diff with 3 parallel agents by attack category |
| `/ship:review` | Code review focused on SOLID, DRY, KISS, Clean Code, and project consistency |
| `/ship:analyze` | Detects drift between spec, code, and tests — gate PASS/WARN/FAIL |
| `/ship:homolog` | Presents the final quality report and awaits approval |
| `/ship:pr` | Creates the Pull Request with atomic commits and aggregated quality report |

### Audit — for periodic project-wide reviews

These commands analyze the **entire project**, not just the current diff. Use them before releases, in periodic health reviews, or when you want to understand the overall state of the system.

| Command | What it does |
|---------|--------------|
| `/ship:audit:backend` | Project-wide backend performance audit — 3 parallel agents, stack-aware |
| `/ship:audit:frontend` | Project-wide frontend performance audit — routes to Next.js (5 layers) or generic methodology (11 categories) |
| `/ship:audit:database` | Project-wide database audit — detects and uses MongoDB, PostgreSQL, or MySQL methodology |
| `/ship:audit:security` | Full AppSec audit — OWASP Top 10, CWE mapping, A-F score, PoC for critical and high findings |
| `/ship:audit:tests` | Test coverage audit — maps acceptance criteria against existing tests and reports gaps by layer |
| `/ship:audit:run` | Runs all applicable audits in parallel and consolidates results into a single report |

> **Important:** audit commands are **never** called automatically by `/ship:run`. They exist to be triggered manually when it makes sense — not on every task.

---

## Configuration

When you run `/ship:init`, Ship creates a `ship/config.md` file in your project root. This file controls the behavior of the entire pipeline.

```markdown
# Ship Config

## Project
- Name: My Project
- Type: backend          # backend | frontend | fullstack | mobile | prompt-toolkit

## Linear Integration
- Configured: yes
- Team: Engineering
- Team ID: <your-team-id>

## Pipeline Profile
- profile: standard      # lite | standard | strict

## Pipeline Phases
- dev: enabled
- test: enabled
- perf: enabled
- security: enabled
- review: enabled
- homolog: enabled
- pr: enabled

## Gate Behavior
- on_fail: ask           # ask | fix | defer
- on_warn: ask           # ask | fix | pass
- on_fail_rerun: surgical   # surgical | full

## Conventions
- Artifact language: en  # Language for specs, issues, docs, milestones, reports
- Commit style: Conventional Commits
- Atomic commits: one logical change per commit

## Test Scope
- unit: enabled
- integration: enabled
- e2e: disabled

## Scenario Depth
- depth: full            # none | light | full
```

### Pipeline Profiles

The `profile` field sets the default behavior of the pipeline:

| Profile | Description |
|---------|-------------|
| `lite` | Implementation and tests only — ideal for fast iterations |
| `standard` | All phases with balanced depth — recommended default |
| `strict` | All phases with exhaustive checks — gates block even on warnings |

You can adjust individual phases in `Pipeline Phases`. The `profile` sets the defaults; individual entries override them.

### Quality Gates

At each phase, Ship classifies findings by severity and decides what to do:

- `critical` or `high` findings → gate **FAIL** → pipeline stops
- `medium` findings → gate **WARN** → pipeline pauses and asks the user
- `low` or no findings → gate **PASS** → pipeline continues

The `on_fail` field controls what happens on a FAIL gate: `ask` (pause and ask), `fix` (agent attempts to fix automatically), or `defer` (creates a tracking issue and continues). The `on_warn` field does the same for WARNs: `ask`, `fix`, or `pass` (continues without action). The `on_fail_rerun` field controls the scope when a phase reruns: `surgical` (only the files with findings) or `full` (entire phase from scratch).

### Storage: Linear or Local

Ship works in two modes depending on whether you have Linear MCP configured:

**Linear Mode (recommended):** all artifacts — proposals, designs, tasks, quality reports — live in Linear as documents and issue comments. The only local file is `ship/config.md`.

**Local Mode (fallback):** artifacts are written to `ship/changes/<feature>/` as markdown files.

```
ship/
├── config.md
├── changes/
│   └── <feature-name>/
│       ├── proposal.md
│       ├── design.md
│       ├── tasks.md
│       ├── report-<task>.md
│       └── tracking.md
└── audits/
    ├── backend-<date>.md
    ├── frontend-<date>.md
    ├── database-<date>.md
    ├── security-<date>.md
    ├── tests-<date>.md
    └── run-<date>.md
```

### Test Scope

The `Test Scope` field controls which test layers `/ship:test` generates during the pipeline:

| Project type | unit | integration | e2e |
|--------------|------|-------------|-----|
| `prompt-toolkit` / library | enabled | disabled | disabled |
| `backend` / `fullstack` | enabled | enabled | disabled |
| `frontend` | enabled | disabled | disabled |
| `monorepo` | enabled | enabled | disabled |
| `mobile` | enabled | disabled | disabled |

Disabled layers are not generated during the normal pipeline. To audit and backfill those gaps, use `/ship:audit:tests`.

> `/ship:analyze` detects drift only within enabled layers; `/ship:audit:tests` audits all project layers regardless of this setting.

### Scenario Depth

The `Scenario Depth` field controls how many test scenarios `/ship:spec` creates per acceptance criterion:

| Value | Behavior |
|-------|----------|
| `none` | No scenarios — spec contains only ACs and requirements |
| `light` | Happy-path scenario only per AC |
| `full` | Full set per AC: happy path + edge cases + error cases (default) |

When `depth` is `light` or `full`, each scenario gets tags like `@SC-01`, `@AC-02`. These tags travel through the entire pipeline:

- `/ship:develop` — implements code to satisfy each `@SC-XX`
- `/ship:test` — generates one test per scenario without re-deriving them
- `/ship:analyze` — correlates scenarios with tests and reports what's covered
- `/ship:audit:tests` — does this correlation across the entire project by layer

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| Claude Code | Required — Ship is a Claude Code plugin |
| Linear MCP | Optional — enables Linear Mode for artifact storage |

No other dependencies. No Node.js. No database. No binary to install or maintain.

---

## License

MIT
