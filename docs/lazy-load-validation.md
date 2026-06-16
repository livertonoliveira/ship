# Lazy-load validation — resume notes

Pick-up point for validating the lazy-load work against a **real Linear issue**. The
deterministic suite (`scripts/e2e-validate.sh`) and a Local-mode smoke
(`scripts/e2e-smoke.sh`) already pass; what they *cannot* exercise is the Linear path
and a couple of conditional branches. This doc is the thread to resume that.

## Context (what we changed)

Token-efficiency work on branch `ship-token-efficiency-audit` (8 commits, `529365e..HEAD`):

- **Fase 1** — orchestrator writes `spec.md`/`design.md` to the scratch dir once; phases
  read diff/spec/design from there instead of being re-inlined (`e9f5891`).
- **Fase 3** — `build.js` inlines each pattern **once per file** (was N×, a bug) (`f55dbda`).
- **Fase 4** — lazy refs `@@ship/<path>.md` → bundled next to the skill + replaced with
  `${CLAUDE_SKILL_DIR}/<path>`; the model reads them on demand (`22fcab9`, `55ad50d`).

Mechanism reference: `src/patterns/skill-patterns-convention.md`. Memory:
`project_ship_pattern_loading_mechanisms`.

How lazy works at runtime: `${CLAUDE_SKILL_DIR}` is substituted into the **skill body at
render time** (validated — the Read tool received a real absolute path). So a skill line
like ``read `${CLAUDE_SKILL_DIR}/patterns/linear-status.md` `` becomes an absolute path the
model Reads on demand. Bundled files live at `plugins/ship/skills/<name>/patterns/`.

## Lazy reads and their validation status

| Lazy pattern | Where | Triggered when | Validated? |
|---|---|---|---|
| `model-routing` | run (banner) | every run | ✅ Local smoke ran it |
| `model-routing` | init | `/ship:init` only | ⚠️ not yet |
| `linear-status` | run, develop, homolog, pr | **Linear mode only** | ⚠️ not yet |
| `gates` | run | only on a **fix re-run** (gate FAIL/WARN + `on_fail/on_warn: fix`) | ⚠️ not yet |

The ⚠️ rows are skipped by the Local-mode smoke by design.

## What to validate on a real Linear run

Run `/ship:run <LINEAR-ISSUE-ID>` (Linear mode configured) and watch for:

1. **`linear-status` lazy read fires.** The orchestrator/develop must actually issue a
   `Read` of `…/patterns/linear-status.md` before transitioning the issue, then resolve the
   team's started/completed **state name** (not the literal `"In Progress"`/`"Done"`) and
   call `save_issue`. Good signal: issue moves to its started state at the beginning and to
   its completed state at homolog/pr.
2. **No "file not found" / literal `${CLAUDE_SKILL_DIR}`.** If you ever see the model try to
   Read a path containing the literal text `${CLAUDE_SKILL_DIR}` (unsubstituted), the
   render-time substitution did not happen for that surface → see Rollback.
3. **(Optional) gates lazy read.** To exercise it, force a fixable finding with
   `Gate Behavior → on_warn: fix` (or `on_fail: fix`) so a surgical re-run runs; confirm the
   orchestrator Reads `…/patterns/gates.md` before applying the re-run procedure.
4. **(Optional) init lazy read.** Run `/ship:init` in a fresh project; it should still detect
   stack and write `ship/config.md` correctly (the `model-routing` ref is citational).

## "Good" vs failure signature

- **Good:** issue transitions happen; no unsubstituted `${CLAUDE_SKILL_DIR}` anywhere; the
  recipe content clearly informed the state resolution.
- **Failure:** model can't find the file, or skips the read and guesses a state name (e.g.
  passes literal `"Done"` → silent no-op, issue stays open). That means the lazy read isn't
  reliable for that surface.

## Rollback (if a lazy surface proves unreliable)

The change is per-reference and trivially reversible: in the offending `src/skills/*/SKILL.md`,
change that pattern's `@@ship/patterns/<x>.md` back to `@ship/patterns/<x>.md` (inline) and
drop the "read … and follow that recipe" wording, then `cd plugins/ship && npm run build`.
That restores build-time inlining for just that surface; everything else stays lazy. Re-run
`scripts/e2e-validate.sh` to confirm green.

## Quick commands

```bash
scripts/e2e-validate.sh                     # deterministic guard (run after any edit)
scripts/e2e-smoke.sh --fixture tictactoe    # live Local-mode pipeline smoke
cd plugins/ship && npm run build            # rebuild plugins/ from src/
```
