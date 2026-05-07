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
  <strong>Ship — Development pipeline as Claude Code slash commands — zero dependencies</strong><br>
  From raw idea to delivered Pull Request — spec, implement, test, audit, and ship with a single command.
</p>

<p align="center">
  <a href="#what-is-ship">What is Ship</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#requirements">Requirements</a>
</p>

---

## What is Ship

Claude Code is a powerful tool. Ship turns it into a complete development pipeline.

Delivering a feature the "normal" way with an LLM (Large Language Model) means juggling a dozen tabs: requirements, tasks, tests, security review, performance analysis, PR (Pull Request) description, tracker update, commit discipline. Each one burns context. Each one is one prompt away from being forgotten.

Ship replaces that chaos with a **deterministic, repeatable pipeline** built entirely on Claude Code slash commands:

- **One command specifies the entire feature.** `/ship:spec "add password reset"` creates a Linear project with milestones, labels, and granular tasks — each sized to fit cleanly in a single session.
- **One command delivers the task.** `/ship:run TASK-ID` executes develop → test → performance → security → review → acceptance, with parallel agents and a quality gate at every phase.
- **One command ships the PR.** `/ship:pr` produces atomic Conventional Commits and a PR with an aggregated quality report.

Because Ship is purely a set of Claude Code slash commands (prompt-toolkit), it requires **no binary, no runtime, no database**. Install once, works everywhere Claude Code runs.

### Before vs. After Ship

| Without Ship | With Ship |
|---|---|
| Feature planning in free-form chat | Linear project with granular tasks (<400 lines each) |
| "Please review this" | 3 parallel agents: performance + security + SOLID/DRY/KISS |
| Ad-hoc test coverage | Unit + integration + e2e generated in parallel |
| Manual OWASP eyeballing | Automated security scan on every diff with policy gate |
| "Initial commit" × 20 | Atomic Conventional Commits by design |
| Session crashes mid-pipeline | Persistent artifacts in Linear or local markdown |

---

## Installation

### Plugin (primary method)

```bash
claude plugin marketplace add livertonoliveira/ship
claude plugin install ship
```

The plugin registers all `/ship:*` slash commands in Claude Code automatically. No configuration required to start.

### curl (fallback)

```bash
curl -fsSL https://raw.githubusercontent.com/livertonoliveira/ship/main/install.sh | bash
```

This places the command files into `.claude/commands/ship/` in your project and registers them with Claude Code.

### Zero dependencies

Ship does **not** require:
- Node.js or npm
- PostgreSQL or any database
- Any installed binary or runtime

It is a pure prompt-toolkit: slash commands that instruct Claude Code agents. The only requirement is Claude Code itself.

---

## Quick Start

```bash
# 1. Initialize Ship in your project (run once per project)
/ship:init

# 2. Specify a feature — creates Linear project, milestones, and tasks
/ship:spec "add email notifications for order status changes"

# 3. Run the full pipeline for a task
/ship:run MOB-42

# 4. Ship the PR with atomic commits and quality report
/ship:pr
```

That's the complete flow. Each step builds on the previous one: `spec` creates structured tasks, `run` executes the full develop → test → quality pipeline for each task, and `pr` packages everything into a clean, reviewable Pull Request.

---

## Commands

### Pipeline Commands

| Command | Purpose |
|---------|---------|
| `/ship:init` | Initialize Ship in a project — detects stack, conventions, configures Linear, creates `ship/config.md` |
| `/ship:spec` | Deep specification: decompose a feature into granular tasks (<400 lines), create Linear project with milestones and issues |
| `/ship:run` | Full development pipeline for a task: develop → test → perf → security → review → analyze → homolog |
| `/ship:develop` | Implement code following project conventions (can run standalone or inside `/ship:run`) |
| `/ship:test` | Generate and run tests — unit, integration, and e2e — with 3 parallel agents |
| `/ship:perf` | Performance analysis of the diff — detects project type and adapts agents accordingly |
| `/ship:security` | OWASP (Open Web Application Security Project) security scan of the diff with 3 parallel agents by attack category |
| `/ship:review` | Code review focused on SOLID, DRY, KISS, Clean Code, and project consistency |
| `/ship:analyze` | Drift detection: map spec→code→tests, detect gaps, gate PASS/WARN/FAIL |
| `/ship:homolog` | Final quality report + user acceptance approval |
| `/ship:pr` | Create PR (Pull Request) with atomic Conventional Commits and aggregated quality report |
| `/ship:update` | Update all Ship command files to the latest version |

### Audit Commands

Audit commands are **project-wide** — they scan the entire codebase for systemic issues. Run them periodically or before releases. Unlike pipeline phases, audits are not diff-scoped.

| Command | Purpose |
|---------|---------|
| `/ship:audit:backend` | Project-wide backend performance audit — 3 parallel agents, stack-aware |
| `/ship:audit:frontend` | Project-wide frontend performance audit — auto-routes to Next.js (5 layers) or generic (11 categories) |
| `/ship:audit:database` | Project-wide database audit — routes to MongoDB, PostgreSQL, or MySQL methodology |
| `/ship:audit:security` | Project-wide AppSec (Application Security) audit — OWASP Top 10, CWE mapping, A-F score, PoC for critical/high |
| `/ship:audit:run` | Run all applicable audits in parallel; produces a consolidated gate report |
| `/ship:audit:tests` | Project-wide test coverage audit — maps AC/REQ ↔ existing tests, reports gaps by layer |

---

## Configuration

After `/ship:init`, Ship creates `ship/config.md` in your project root. This file controls every aspect of the pipeline.

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
```

### Pipeline Profiles

| Profile | Description |
|---------|-------------|
| `lite` | Fast feedback loop — dev + test only |
| `standard` | Balanced — all phases, medium depth |
| `strict` | Maximum quality — all phases, exhaustive checks, gates block on warn |

Individual phases can be toggled independently. The `profile` sets defaults; entries in `Pipeline Phases` override them.

### Gate Behavior

Gates stop or redirect the pipeline based on finding severity:

- `critical` or `high` findings → gate **FAIL** → pipeline stops
- `medium` findings → gate **WARN** → pipeline pauses, asks user
- `low` or no findings → gate **PASS** → pipeline continues

The `on_fail` setting controls what happens on a FAIL gate: `ask` (pause and ask the user), `fix` (agent attempts to fix automatically), or `defer` (create a tracking issue and continue). The `on_warn` setting controls WARN gates: `ask`, `fix`, or `pass` (continue without action). The `on_fail_rerun` setting controls rerun scope: `surgical` (only re-run the files with findings) or `full` (re-run the entire phase from scratch).

### Linear Integration

When Linear MCP (Model Context Protocol) is configured, Ship operates in **Linear Mode**: all artifacts (proposals, designs, tasks, quality reports) live in Linear as documents and issue comments. Zero local files are created beyond `ship/config.md`.

Without Linear, Ship falls back to **Local Mode**: artifacts are written to `ship/changes/<feature>/` as markdown files.

### Test Scope

The `Test Scope` section in `ship/config.md` controls which test layers `/ship:test` generates during the pipeline:

```markdown
## Test Scope
- unit: enabled        # Unit tests (always recommended)
- integration: enabled # Integration/API tests
- e2e: disabled        # End-to-end tests (via /ship:audit:tests for backfill)
```

**Defaults by project type:**

| Type | unit | integration | e2e |
|------|------|-------------|-----|
| `prompt-toolkit` / library | enabled | disabled | disabled |
| `backend` / `fullstack` | enabled | enabled | disabled |
| `frontend` | enabled | disabled | disabled |
| `monorepo` | enabled | enabled | disabled |
| `mobile` | enabled | disabled | disabled |

Disabled layers are **not** generated during the pipeline. Use `/ship:audit:tests` to audit and backfill coverage for disabled layers project-wide.

> **Note:** `/ship:analyze` detects drift only within the **enabled** Test Scope layers; `/ship:audit:tests` audits **all** layers project-wide regardless of pipeline config.

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| Claude Code | Required — Ship is a Claude Code plugin |
| Linear MCP | Optional — enables Linear Mode for artifact storage |

No other dependencies. No Node.js. No database. No binary to install or maintain.

---

## Storage Modes

### Linear Mode (recommended)

All artifacts live in Linear — zero local files except `ship/config.md`:

- **Proposal & Design** → Linear Documents linked to the project
- **Tasks** → Linear Issues with milestones and labels
- **Quality Reports** → Comments on task issues
- **Tracking** → Linear sub-issues

### Local Mode (fallback)

All artifacts live in `ship/changes/<feature>/` as markdown:

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

---

## License

MIT
