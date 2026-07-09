# Word budget for SKILL.md files

The build (`plugins/ship/scripts/build.js`) walks `src/skills/**/SKILL.md` and `src/agents/*.md`, resolves refs (`@ship/...`), and writes the compiled output to `plugins/ship/`. After `buildSkills()` writes each compiled SKILL.md, a verification gate counts the words of the already-substituted content (`countWords`) and compares it against a per-tier ceiling (`checkBudget`), reading the values from `plugins/ship/scripts/budgets.js`. Any skill that exceeds its tier's ceiling stops the build with `process.exit(1)`.

## Tiers and ceilings

Ceilings are defined in `plugins/ship/scripts/budgets.js` (source of truth).

| Tier | Ceiling (words) | Skills |
|------|------------------|--------|
| orchestrator | 8000 | `run` |
| heavy | 4000 | `spec`, `pr` |
| phase | 3000 | `test`, `develop`, `plan`, `homolog`, `init`, `audit:run`, `perf`, `security`, `review`, `analyze` |
| small | 900 | `audit:backend`, `audit:database`, `audit:frontend`, `audit:security`, `audit:tests` |

## Rationale

What the model pays for in context cost is the **compiled** SKILL.md — with refs already inlined — not the source file in `src/skills/`. That's why the gate measures the output of `buildSkills()`, not the content of `src/**`.

Per-tier ceilings were fixed at the size each skill reached after a round of no-op/boilerplate pruning, plus roughly 10–15% headroom. This allows moderate organic growth without requiring a ceiling adjustment for every small change, while still preventing a skill from inflating indefinitely without review.

## When the build fails on budget

If `build.js` reports that a skill exceeded its ceiling, follow this order:

1. **Try pruning first.** Remove no-ops, compress verbose paragraphs into leading-words, consolidate duplicated boilerplate by extracting it into `src/patterns/*.md` and referencing it via `@ship/...`. The goal is to reduce the word count without changing the skill's observable behavior.
2. **Only after reasonable pruning is exhausted, adjust the ceiling.** Change the corresponding tier's value in `plugins/ship/scripts/budgets.js`, or add an explicit entry for the skill in `WORD_BUDGETS` if it warrants its own ceiling outside the standard tier. Justify the increase in the PR description.

## Skills without an explicit entry

Any `skillKey` without an explicit entry in `WORD_BUDGETS` falls back to `DEFAULT_BUDGET` (1000 words). This covers new skills created without a deliberate tier decision — the goal is to force a conscious tier choice once the skill grows past this default ceiling.
