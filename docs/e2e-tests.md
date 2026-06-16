# Ship E2E tests

Two complementary harnesses validate Ship without depending on Linear (both use
**Local mode** — self-contained, no external services, no side effects).

## Tier 1 — deterministic (`scripts/e2e-validate.sh`)

Offline, free, fast. Asserts the build + pattern-reference mechanics: no drift
between `src/` and `plugins/`, no unresolved `@ship`/`@@ship` tokens, every
`${CLAUDE_SKILL_DIR}` lazy ref has its bundled file, bundled patterns are
self-contained, size budgets, and the structural lints. Run on every change / in CI.

```bash
scripts/e2e-validate.sh
```

## Tier 2 — live headless smoke (`scripts/e2e-smoke.sh`)

Drives the REAL pipeline against the local plugin build via
`claude --print --plugin-dir plugins/ship` in a throwaway git project (Local mode):
`/ship:spec` → `/ship:run` (dev→test→perf→security→review→analyze→homolog). Asserts
the scratch-dir artifacts exist, source + tests were produced, the generated suite
passes (`node --test`, zero-dependency), and the expected phases appear in the trace.

Ship is LLM-driven, so this checks the machinery and passing tests — not exact code.
Costs tokens and takes several minutes; run before releases / after big changes.

```bash
scripts/e2e-smoke.sh                      # calculator, full pipeline
scripts/e2e-smoke.sh --fixture tictactoe  # alternative fixture
scripts/e2e-smoke.sh --scope lite         # dev+test only (cheaper)
scripts/e2e-smoke.sh --keep               # keep the temp project for inspection
```

Requires `claude` on PATH and Node.js. Linear-specific paths (issue transitions,
the lazy `linear-status` recipe) are NOT exercised here — validate those manually.
