# Ship Shared Patterns — Index

Navigation index for human reference. **Do not reference this file from command files** — include only the specific pattern files you need from `ship/patterns/`.

## Available patterns

| File | Use when | Lines |
|------|----------|-------|
| [`ship/patterns/storage-mode.md`](patterns/storage-mode.md) | Command needs to detect Linear vs Local mode | 5 |
| [`ship/patterns/load-artifacts.md`](patterns/load-artifacts.md) | Command needs to load context artifacts | 12 |
| [`ship/patterns/gates.md`](patterns/gates.md) | Command emits a gate decision (PASS/WARN/FAIL) | 7 |
| [`ship/patterns/severity.md`](patterns/severity.md) | Command classifies findings by severity or applies Severity Overrides from config | 103 |
| [`ship/patterns/parallelism.md`](patterns/parallelism.md) | Command launches parallel agents | 5 |
| [`ship/patterns/language.md`](patterns/language.md) | All commands (language rule) | 4 |
| [`ship/patterns/stack-detection.md`](patterns/stack-detection.md) | Command needs to read or detect the project's stack | 44 |
| [`ship/patterns/profiles.md`](patterns/profiles.md) | Command needs to resolve the active pipeline profile | 45 |
| [`ship/patterns/lazy-load-findings.md`](patterns/lazy-load-findings.md) | Command renders findings sections (quality reports, PR body) | 40 |
| [`ship/patterns/run-context.md`](patterns/run-context.md) | Orchestrator (`run.md`) manages shared scratch dir; agents read from it | 109 |
| [`ship/patterns/security-categories.md`](patterns/security-categories.md) | Security commands resolve `Security Focus → categories` from config to active OWASP IDs | ~50 |

## Which patterns each command needs

| Command | storage-mode | load-artifacts | gates | severity | parallelism | language | stack-detection | profiles | lazy-load | run-context | security-categories |
|---------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| develop.md | ✓ | ✓ | | | ✓ | ✓ | | | | | |
| test.md | ✓ | ✓ | | | ✓ | ✓ | | | | | |
| perf.md | ✓ | ✓ | | | ✓ | ✓ | ✓ | | | | |
| security.md | ✓ | ✓ | | | ✓ | ✓ | ✓ | | | | ✓ |
| review.md | ✓ | ✓ | | | | ✓ | | | | | |
| homolog.md | ✓ | ✓ | | | | ✓ | | | ✓ | ✓ | |
| run.md | ✓ | ✓ | | | ✓ | ✓ | ✓ | ✓ | | ✓ | |
| pr.md | ✓ | ✓ | | | | ✓ | | | ✓ | ✓ | |
| spec.md | ✓ | ✓ | | | ✓ | ✓ | | | | | |
| init.md | | | | | | ✓ | ✓ | | | | |
| audit/backend.md | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | | | |
| audit/frontend.md | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | | | |
| audit/security.md | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | | | |
| audit/database.md | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | | | | |
| audit/run.md | ✓ | ✓ | | | ✓ | ✓ | ✓ | | | | |

## Pre-quality Snapshot and on_fail_rerun

Before the parallel quality phases (perf / security / review) begin, the orchestrator writes the current HEAD SHA to `.context/ship-run/<task-id>/pre-quality-snapshot.sha`. This snapshot is used by:

- The **PR agent** (`pr.md`) to build the correct diff for the pull request.
- The **orchestrator** (`run.md`) after auto-fix to decide which phases to re-run, controlled by the `on_fail_rerun` flag in `ship/config.md → Gate Behavior`.

`on_fail_rerun` accepts two values: `surgical` (default — re-run only failed/warned phases) and `all` (re-run every quality phase after auto-fix).

For full details, format, and lifecycle rules: see `ship/patterns/gates.md → Snapshot pré-fix`.

---

## Lazy-Load Findings Principle

> Carregar conteúdo de findings sob demanda — apenas quando o gate sinalizar problema.
> Para PASS, exibir resumo + link. Para WARN/FAIL, expandir só fases problemáticas com severidade ≥ medium.

- **PASS**: emit a compact summary table row or single-line `✓ Phase: PASS (0 critical/high) — [see full report](<link>)`. No inline findings.
- **WARN / FAIL**: embed all critical/high/medium findings in full; aggregate low findings into a single count line.
- For the exact rendering format: `@ship/report-templates.md#lazy-mode`
- For the decision algorithm: `@ship/patterns/lazy-load-findings.md`

---

## Orchestrator vs Sub-agent Pattern

Gate and severity classification belong to the **orchestrator**, not to sub-agents.

### Rule

Sub-agents spawned by `ship:perf`, `ship:security`, and `ship:review` must NOT reference `@ship/patterns/gates.md` or `@ship/patterns/severity.md`. These files are loaded once in the orchestrator's context; spreading them to every sub-agent multiplies token cost with no benefit (e.g., in a fan-out of 3, `gates.md` + `severity.md` would be read 3× each).

### Implementation

- **Sub-agents** (Agent A/B/C in security, Backend/Frontend in perf, module agents in review): use inline minimal severity labels (critical/high/medium/low) and return raw findings only.
- **Skill orchestrator** (ship:perf, ship:security, ship:review consolidation steps): uses inline condensed severity definitions and gate rules — NOT `@`-referenced files.
- **Standalone fallback**: when a skill runs outside `ship:run`, it applies severity overrides from `ship/config.md` and computes the gate inline.
- **Pipeline mode**: the skill computes a preliminary gate for the report; `ship:run` re-evaluates after applying severity overrides.

### Patterns NOT needed by sub-agents

| Pattern | Needed by | NOT needed by |
|---------|-----------|---------------|
| `gates.md` | ship:run orchestrator | perf/security/review sub-agents |
| `severity.md` | ship:run orchestrator | perf/security/review sub-agents |
| `storage-mode.md` | Each skill entry point | Internal sub-agents |
| `run-context.md` | ship:run + skill entry points | Internal sub-agents |
| `parallelism.md` | Each skill entry point | Internal sub-agents |
| `lazy-load-findings.md` | homolog, pr | Quality phase skills |
