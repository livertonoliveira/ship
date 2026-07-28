# Gate Rules

## Gate Decision Rules {#gate-decision-rules}

Gate decision rules applied after every quality phase:

- Any `critical` or `high` finding → **FAIL**
- Any `medium` finding → **WARN**
- Only `low` or no findings → **PASS**

A phase row whose Gate column reads `fail` also forces **FAIL** even with zero severity counts — that is how a red typecheck or a red suite blocks, since those phases report a failure without minting findings.

Gate behavior on FAIL/WARN is configured in `ship/config.md → Gate Behavior` (`on_fail`, `on_warn`).

> See `worker-status.md` for the orthogonal completion axis (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED) — a worker's completion state is independent of the PASS/WARN/FAIL gate result documented here.

## One consolidated gate

Every detector reports into a single gate: typecheck/lint (`static`), the suite (`test`), coverage regression (`test-generate`) and the quality phases (`perf`, `security`, `review`). None of them halts the pipeline on its own.

This is deliberate. When static red blocked the fan-out and a red suite blocked the gate, the three detectors never held their results at the same instant, so a complete list of the adjustments a round required could not exist — the pipeline had to discover it across three serialized detect→fix→re-detect cycles.

## Remediation batch

When the gate is red and the configured action is `fix`, `pipeline.sh next` builds `remediation.md` **once** via `remediation.sh`: the deterministic failures plus every finding, each with a stable id (`R1`, `R2`, …), mirrored in `remediation-items.txt` as `R<N>|<kind>|<phase>|<severity>|<file>|<slug>`.

One fix agent consumes the whole batch in one pass. There is no per-phase fix agent and no per-finding fix agent.

## Closed-set confirmation

After the fix returns, the pipeline does **not** re-dispatch the quality workers. It:

1. Re-runs the deterministic checks — for typecheck, the suite and coverage, running the check *is* the verdict.
2. Dispatches one confirmation agent, but only over the batch's finding items, asking a closed question per id: is this specific finding addressed? It writes `remediation-verify.md` as `- <id>: resolved` or `- <id>: unresolved — <reason>`. An item with no answer counts as unresolved: silence is not evidence.
3. Scores the answers with `remediation-verify.sh`, which rewrites each affected `phase-status-<phase>.md` counting only the findings that survived.

The gate then re-evaluates from those refreshed rows.

This is what makes the loop terminate. The old post-fix pass re-dispatched `perf`/`security`/`review` as fresh open-ended audits of code the fix had just written, and an open-ended audit of new code always finds new nits — so the gate never converged on its own and needed a 3-round cap, a finding-identity ledger and a churn guard to stop it. A closed question set cannot mint a finding that was not already in the batch, so the set shrinks or stalls, never grows. All three guards are gone.

## One automatic round

`remediation-done.txt` marks the round as spent. It survives `--mode resume` (a re-queued `/ship:run` or recovery after an interruption) and is cleared only by `--mode fresh`.

With residue after that round the gate stops deciding and asks:

- **FAIL** → `fix now` (another round, explicitly) | fix manually then `--answer defer` | `defer` (proceed, registering pending findings).
- **WARN** → `fix now` | `pass` (proceed).

Warnings are remediated like failures — a `medium` finding enters the batch exactly as a `critical` one does. What used to make warnings expensive was the open-ended re-audit that regenerated them, not the act of fixing them.

## Edge cases

**Nothing remediable.** The gate is red but no item could be extracted from the phase artifacts (a phase reported `fail` with no findings file). `gate-resolved.txt` = `<decision> no-batch`; the pipeline surfaces `phase-status.md` to the user rather than dispatching a fix agent with an empty list.

**Suite timeout.** A suite that hangs past 300s is the one failure the batch cannot absorb — there is no failure list to remediate, only an unknown. The pipeline stops for manual intervention.
