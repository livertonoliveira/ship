# Ship — Development Pipeline Framework

Ship is a set of Claude Code slash commands (`/ship:*`) that automates the complete development pipeline: from issue intake to PR creation, with persistent MD artifacts and continuous tracking.

## Commands

| Command | Purpose |
|---------|---------|
| `/ship:init` | Initialize Ship in a project (run once) |
| `/ship:spec` | Deep specification: requirements, design, granular tasks (<400 lines), Linear project/milestones/issues |
| `/ship:run` | Development pipeline for a task: develop → test → quality → homologation |
| `/ship:develop` | Implement code following project conventions |
| `/ship:test` | Generate and run tests (unit, integration, e2e) |
| `/ship:perf` | Performance analysis of the diff |
| `/ship:security` | OWASP security scan of the diff |
| `/ship:review` | Code review (SOLID, DRY, KISS) |
| `/ship:analyze` | Drift detection: map spec→code→tests, detect gaps, gate PASS/WARN/FAIL |
| `/ship:homolog` | Final report + user homologation |
| `/ship:pr` | Create PR with atomic commits and aggregated quality report |
| `/ship:audit:backend` | Project-wide backend performance audit (3 parallel agents) |
| `/ship:audit:frontend` | Project-wide frontend performance audit (Next.js 5-layer or generic 11-category) |
| `/ship:audit:database` | Project-wide database audit (MongoDB / PostgreSQL / MySQL) |
| `/ship:audit:security` | Project-wide AppSec audit — OWASP Top 10, A-F score, PoC for critical/high |
| `/ship:audit:run` | Run all applicable audits in parallel; consolidated gate report |

## Storage Modes

Ship operates in two modes based on whether Linear is connected:

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
├── config.md                    # Project context (always local)
├── changes/
│   ├── <feature-name>/
│   │   ├── proposal.md          # Requirements, acceptance criteria, scope
│   │   ├── design.md            # Technical decisions, architecture
│   │   ├── tasks.md             # Granular tasks (<400 lines each)
│   │   ├── report-<task>.md     # Quality reports per task
│   │   └── tracking.md          # Issue tracking
│   └── archive/                 # Completed features
└── audits/                      # Project-wide audit reports
    ├── backend-<date>.md
    ├── database-<date>.md
    ├── frontend-<date>.md
    ├── security-<date>.md
    └── run-<date>.md            # Consolidated audit suite report
```

## Conventions

### Language
- Command instructions (LLM prompts): always in English — never configurable
- User-facing text during pipeline execution (reports, summaries, gate results, questions to the user): use the `Artifact language` field from `ship/config.md`
- Code, variable names, commits, branch names: always in English

### Parallelism
- Always use the Agent tool to parallelize work
- Never execute sequentially what can be parallel
- Each parallel agent writes to separate files (no race conditions)

### Gates
- `critical` or `high` findings → gate `fail` → pipeline stops
- `medium` findings → gate `warn` → pipeline pauses, asks user
- Only `low` or no findings → gate `pass` → pipeline continues

### Tracking
- With Linear: create detailed sub-issues for each finding, update status continuously
- Without Linear: register everything in `tracking.md` with rich detail (Context, What to do, Acceptance Criteria)

### Commits and PRs
- Follow Conventional Commits: `feat:`, `fix:`, `refactor:`, `test:`, `chore:`
- Atomic commits — one logical change per commit
- Never group unrelated changes
- Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
- Branch naming: `<type>/<issue-id>-<short-description>`

### Stack Agnostic
- Ship works with any stack. The `/ship:init` command detects the project's stack dynamically.
- All analysis commands adapt their checks based on `ship/config.md`.
- Never hardcode stack-specific assumptions — always read from config.

### Audit vs Pipeline Phases
- **Pipeline phases** (`/ship:perf`, `/ship:security`) are diff-scoped: they analyze only changed code during the development pipeline.
- **Audit commands** (`/ship:audit:*`) are project-wide: they scan the entire codebase for systemic issues. Run them periodically or before releases.
- `/ship:audit:run` launches all applicable audits in parallel and produces a consolidated gate report.

### Integration with Global Skills
- The `/ship:audit:*` commands incorporate the methodology from global skills (`backend-performance-audit`, `security-audit`, `mongodb-audit`, `frontend-performance-audit`, `nextjs-performance-audit`) translated to English and adapted to Ship conventions.
- `/ship:pr` can replace the default PR workflow by adding the aggregated quality report
