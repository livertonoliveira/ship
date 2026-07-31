# Ship — Development Pipeline Framework

Ship is a set of Claude Code slash commands (`/ship:*`) that automates the complete development pipeline: from issue intake to PR creation, with persistent MD artifacts and continuous tracking.

## Commands

| Command | Purpose |
|---------|---------|
| `/ship:init` | Initialize Ship in a project (run once) |
| `/ship:spec` | Deep specification: requirements, design, granular tasks (<400 lines), Linear project/milestones/issues |
| `/ship:run` | Development pipeline for a task: develop → verify (test ∥ quality, one consolidated gate) → homolog — a thin loop over `pipeline.sh next` |
| `/ship:plan` | Test-aware planning: decompose the task into modules and map scenarios to a test contract (single source of truth for develop + test), validated against the spec and the repo, then confronted with the files each module claims |
| `/ship:develop` | Direct implementer: reads the plan and implements all modules sequentially in one context |
| `/ship:test` | Standalone test fan-out (unit, integration, e2e) — inside the pipeline, `pipeline.sh next` dispatches the test workers directly |
| `/ship:perf` | Performance analysis of the diff |
| `/ship:security` | OWASP security scan of the diff |
| `/ship:review` | Code review (SOLID, DRY, KISS) |
| `/ship:homolog` | Final report + user homologation |
| `/ship:pr` | Create PR with atomic commits and aggregated quality report |
| `/ship:graph` | Cross-task parallelism: runs a feature's independent tasks in isolated workspaces, one `/ship:run` per node, each opening its own PR against the real trunk; the coordinator only polls whether those PRs actually merged |
| `/ship:audit:backend` | Project-wide backend performance audit (3 parallel agents) |
| `/ship:audit:frontend` | Project-wide frontend performance audit (Next.js 5-layer or generic 11-category) |
| `/ship:audit:database` | Project-wide database audit (MongoDB / PostgreSQL / MySQL) |
| `/ship:audit:security` | Project-wide AppSec audit — OWASP Top 10, A-F score, PoC for critical/high |
| `/ship:audit:run` | Run all applicable audits in parallel; consolidated gate report |
| `/ship:audit:tests` | Project-wide test coverage audit — maps AC/REQ ↔ existing tests, reports gaps by layer |

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
    ├── tests-<date>.md
    └── run-<date>.md            # Consolidated audit suite report
```

## Conventions

### Language
- Command instructions (LLM prompts): always in English — never configurable
- User-facing text during pipeline execution (reports, summaries, gate results, questions to the user): use the `Artifact language` field from `ship/config.md`
- Code, variable names, commits, branch names: always in English

### Parallelism
- Parallel fan-out is allowed only where independent read-only analysis or disjoint test layers pay for the per-agent startup cost: the quality phases (`/ship:perf`, `/ship:security`, `/ship:review`), the test layers in `/ship:test`, and the `/ship:audit:*` commands
- Everything else runs sequentially in a single context — `/ship:develop` implements all modules itself, in dependency order, with no leaf workers
- Each parallel agent writes to separate files (no race conditions)
- `/ship:graph` is the one exception, and it is parallelism **between tasks**, not inside one: each node is a whole `/ship:run` in its own workspace, admitted only when its dependency and file-conflict edges allow it. Verification happens per node, against the real trunk: the node syncs its own branch and resolves any conflict in the context that implemented the change, then opens its PR. Nothing inside a task changes.

### Pipeline State Machine

- All of `ship:run`'s sequencing lives in `src/hooks/pipeline.sh` (`pipeline.sh next`): phase ordering, scoping, gating and the single remediation round. The plan confrontation pass is not a phase: it is `/ship:develop`'s own first step, paid inside the context that is about to implement. It is a deterministic script, testable in CI with no runtime installed.
- `run/SKILL.md` is only the executor of what `pipeline.sh next` prints — never re-add phase choreography, gate arithmetic, or ordering decisions to a SKILL or agent file.
- Fix-loop counters and the findings ledger NEVER reset on resume — resetting restarts the loop.

### Work Graph

- The graph's scheduling, conflict edges, PR-state gate and caps live in `src/hooks/graph.sh` — a deterministic script, testable in CI with no runtime installed.
- The coordinator never merges into a shared trunk and never runs a test suite. A dependent node is admitted only once its dependency's PR is **merged on the forge** (`graph.sh poll` reads that state); local pipeline completion is not that signal.
- `graph.sh` must never name a workspace runtime. Everything runtime-specific goes through `src/hooks/driver-<name>.sh` and its four verbs (`dispatch`/`collect`/`wait`/`ask`); `scripts/check-graph-driver-isolation.sh` enforces it.
- `.context/ship-graph/<feature>/` holds the graph state. `graph.sh` is its only writer.

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
- Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
- Branch naming: `<type>/<issue-id>-<short-description>`

### Stack Agnostic
- Ship works with any stack. The `/ship:init` command detects the project's stack dynamically.
- All analysis commands adapt their checks based on `ship/config.md`.
- Never hardcode stack-specific assumptions — always read from config.

### Word-Budget Gate
- Each compiled `SKILL.md` and agent `.md` must stay under a flat 1500-word ceiling enforced by `plugins/ship/scripts/build.js` — no per-file exceptions.
- Aggregate per-group budgets (`run`, `spec`, `audit`) are enforced by `plugins/ship/scripts/run-footprint.js`; they are the guard that actually bounds total context cost.
- See `plugins/ship/scripts/BUDGETS.md` for the ceilings, rationale, and the procedure to follow when a skill legitimately grows.

### Anti-Bloat Rule
- This rule exists because Ship's bloat came from an identifiable dynamic: every behavior bug got fixed by adding defensive prose to a SKILL or agent instead of removing surface or moving the fix to a script, and that pushed a run to 6,900 words even under the word-budget ceiling — new prose can fit under the ceiling and still be the wrong fix.
- Every pipeline behavior fix must either (a) move the logic into a deterministic script/hook, or (b) remove the surface that caused the problem — never add defensive prose to a SKILL or agent file.
- See `plugins/ship/scripts/BUDGETS.md` for the ceilings and the change procedure.

### Audit vs Pipeline Phases
- **Pipeline phases** (`/ship:perf`, `/ship:security`) are diff-scoped: they analyze only changed code during the development pipeline.
- **Audit commands** (`/ship:audit:*`) are project-wide: they scan the entire codebase for systemic issues. Run them periodically or before releases.
- `/ship:audit:run` launches all applicable audits in parallel and produces a consolidated gate report.
- `/ship:audit:tests` audits test coverage across **all** layers project-wide, regardless of which layers the pipeline generates.

> **STRICT RULE — audit commands MUST NOT be invoked from within `ship:run`.**
> `ship:run` is a diff-scoped development pipeline. Audit commands (`audit:backend`, `audit:frontend`, `audit:database`, `audit:security`, `audit:tests`, `audit:run`) are project-wide and must be triggered by the user separately at planned moments (pre-release, periodic health checks). Any SKILL.md or command file that calls an `audit:*` command from inside the pipeline is a bug.

### Test Scope Configuration

The `Test Scope` section in `ship/config.md` controls which test layers `/ship:test` generates during the pipeline:

```
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

Disabled layers are **not** generated during the pipeline but can be backfilled via `/ship:audit:tests`.

### Integration with Global Skills
- The `/ship:audit:*` commands incorporate the methodology from global skills (`backend-performance-audit`, `security-audit`, `mongodb-audit`, `frontend-performance-audit`, `nextjs-performance-audit`) translated to English and adapted to Ship conventions.
- `/ship:pr` can replace the default PR workflow by adding the aggregated quality report
