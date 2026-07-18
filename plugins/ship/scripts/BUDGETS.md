# Word budget for SKILL.md and agent files

The build (`plugins/ship/scripts/build.js`) walks `src/skills/**/SKILL.md` and `src/agents/*.md`, resolves refs (`@ship/...`), and writes the compiled output to `plugins/ship/`. After each file is compiled, a verification gate counts the words of the already-substituted content (`countWords`) and compares it against the ceiling in `plugins/ship/scripts/budgets.js`. Any skill or agent that exceeds the ceiling stops the build with `process.exit(1)`, and the build reports every violation found (not just the first) so all offenders can be fixed in one pass.

## Ceiling

The default ceiling for every compiled `SKILL.md` and every compiled agent `.md` is **999 words**. A narrow **orchestrator tier** (1200 words) exists for `run` and `homolog` — see below. Every other skill or agent uses the default; there are no other per-tier exceptions.

### Orchestrator tier (1200 words) — `run`, `homolog`

Granted 2026-07-18 after a live end-to-end run (`scripts/e2e-smoke.sh`) of the flat-999 `run/SKILL.md` surfaced two real bugs directly caused by the ceiling leaving zero slack:

1. `snapshot-files.sh`'s invocation lost its `@@ship/hooks/...` reference syntax during compression (degraded to bare-filename prose), so the build never bundled the script and the develop evidence-gate silently no-op'd at runtime.
2. Phase 3 ("Testing") lost its explicit `pipeline.sh dispatch` call — present in Phase 2 and Phase 4, missing here — so the test phase never got logged to `dispatch-log.md`/`phase-status.md`; the orchestrator improvised by running the test suite manually instead of dispatching the phase.

Both are consequences of `run/SKILL.md` operating at 994–999/999 words with zero room to word-smith a fix without breaking something else first — confirmed in practice, not hypothesized. `run` and `homolog` are structurally different from every other skill: they are the only two multi-phase orchestrators that wire together literal hook invocations (exact `bash "..."` commands, exact file paths, exact flags) across 6–8 sequential phases, where the failure mode of over-compression is a silently-skipped pipeline step rather than merely thinner prose. 1200 words gives real headroom (~200 words above the point where both bugs were found) without reopening the old unbounded tiers. If a future edit approaches 1200, treat that as the same signal the flat ceiling gives everyone else — prune first, but don't force a cut that drops a concrete `@@ship/...` invocation for vaguer prose.

## Rationale

What the model pays for in context cost is the **compiled** output — with refs already inlined — not the source file in `src/skills/` or `src/agents/`. That's why the gate measures the output of `buildSkills()`/`buildAgents()`, not the content of `src/**`.

A flat sub-1000-word ceiling keeps every prompt loadable at low context cost regardless of which skills/agents a given pipeline run pulls in, and forces prose to stay terse and assertive instead of drifting into exposition over time.

## When the build fails on budget

0. **Check the Anti-Bloat Rule first.** Verify the change does not violate the Anti-Bloat Rule in the root `CLAUDE.md` (`## Conventions` → `### Anti-Bloat Rule`). A ceiling increase motivated by defensive prose is rejected by definition — move the logic to a script/hook or remove the surface instead.
1. **Try pruning first.** Remove no-ops, compress verbose paragraphs into leading-words, consolidate duplicated boilerplate by extracting it into `src/patterns/*.md` and referencing it via `@ship/...` — but remember refs still count their full expanded word cost against the file that references them, so extracting to a pattern only helps if the pattern is trimmed too, or if it lets multiple sections collapse into one shared anchor.
2. **If a pattern file itself is the bulk of several files' word count**, trimming that one pattern is the highest-leverage fix — it reduces every file that references it in one edit.
3. **Only after reasonable pruning is exhausted, escalate to the user.** The ceiling is a deliberate constraint, not a default — do not raise it without an explicit decision to do so, and justify the change in the PR description.

## Skills and agents without an explicit entry

Any `skillKey` without an explicit entry in `WORD_BUDGETS` falls back to `DEFAULT_BUDGET` (999 words). In practice `WORD_BUDGETS` is empty — every skill and agent uses the default.

## Validated, not just assumed (2026-07-18)

`ship-audit-security` needed the deepest cut of any file to fit the ceiling (own prose ~2410 → 228 words after shared-ref overhead; ~91% reduction). Rather than assume that held up, it was validated by actually running the compiled agent against this repo (local-mode override, no Linear writes) and reading its output. Result: it still produced a correct, well-formatted, comprehensive audit — 4 parallel sub-agents covering all 8 category codes, proper OWASP/CWE tagging, a real high-severity finding it verified live against the repo (a `git` guard bypass), and a genuinely novel finding about agent-to-agent trust boundaries. Conclusion: most of what compression removed (verbose OWASP category explanations, elaborate multi-sentence vulnerability writeups) was redundant with the model's own training knowledge — dense category-code hints plus the model's domain expertise reconstructed the detail. This is evidence *for* the flat ceiling holding up even at the extreme, not a reason to add a per-file exception; no exception was granted based on this run. If a future compressed file demonstrably fails in real use (not just "feels thin" on read-through), that's the bar for revisiting its ceiling — see the escalation path above.
