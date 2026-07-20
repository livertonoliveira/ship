# Parallelism Strategy

Parallelism in Ship is **restricted to phases where independent read-only analysis or disjoint test layers amortize the per-agent startup cost**. Everything else runs sequentially, in a single context — implementation especially: modules of one task share conventions and contracts, so one context implementing them in order beats N workers each re-reading the same context.

- **Parallel (the only allowed fan-outs):**
  - Quality stage in `/ship:run`: `perf` + `security` + `review` + `analyze` dispatched as Agents in one turn (plus each worker's internal sub-agents) — read-only diff analysis under independent lenses.
  - Test-layer fan-out in `ship:test`: one `ship-test-*` worker per enabled layer (unit/integration/e2e), one turn — disjoint file sets per layer.
  - `/ship:audit:*` commands — project-wide read-only analysis, user-triggered outside the pipeline.
- **Sequential (everything else):** `ship:develop` writes all modules itself in dependency order (no leaf workers); pipeline phases run one after another (plan → develop → test generation → verification → gate → homolog). Never fan out implementation work.
- When fanning out, launch the N agents in a **SINGLE** assistant turn (multiple `tool_use` blocks); each parallel agent writes to separate files to avoid race conditions.
- When classifying workspaces (monorepo) inside an allowed fan-out: cross-reference the diff/source tree with workspaces in `ship/config.md`, one agent per affected workspace.
- **Never use `run_in_background: true`** (Agent tool) or a backgrounded `Bash` call to dispatch any phase, worker, or leaf agent anywhere in the Ship pipeline. Every dispatch — a test-layer worker or the `perf`+`security`+`review`+`analyze` quality turn — is a **synchronous** tool call: multiple `tool_use` blocks issued in the same assistant turn, which the harness runs concurrently but whose results the orchestrator always awaits before proceeding. "Parallel" in this document means exactly that, never an async/background dispatch. No SKILL.md or agent definition in Ship contains any logic to resume a phase from a background-completion notification — if a phase is dispatched in the background instead, the orchestrator has no way to wait for or consume its result, and will incorrectly consolidate/gate on incomplete data.
