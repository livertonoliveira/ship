# De-identify the worker context — prevention before detection

> A worker emits `SC-43` in a test name mainly because it **received** `SC-43` in its prompt and
> copied it across a boundary it should not have. The most reliable fix is not to forbid the copy
> harder — it is to **not hand over the token in the first place**. Strip the spec IDs from the
> behavioral context you inject; what the worker never sees, it cannot echo.
>
> This is the **primary** defense. The worker-prompt rule ("never put spec IDs in test names") and
> the `PostToolUse` hygiene hook remain as the net for the paths this cannot reach (standalone
> workers that read artifacts directly, a Linear key picked up from the branch, comments — which
> have no input to strip).

## What to strip — when slicing context into a worker prompt

Before you inject `## Scenarios`, `## Test Contract`, `## Module`, or `## Design` into a worker's
prompt, remove from that **injected text only**:

- Scenario / criterion / requirement tags: `@SC-XX`, `@AC-YY`, `@REQ-XX` (and the already-resolved
  layer tag `@unit`/`@integration`/`@e2e` — you used it to route; the worker does not need it).
- Bare spec IDs in prose: `REQ-XX`, `AC-XX`, `SC-XX`, `IMPL-*`, `TEST-*`.
- The task's Linear issue key (`<TEAM>-<n>`, e.g. `MOB-1734`).

## What to KEEP — the behavioral content the worker needs

- The `Scenario:` / `Scenario Outline:` **titles** and the `Given` / `When` / `Then` / `Examples`
  steps. This is the behavior the worker tests, and the `When`/`Then` keywords are exactly what
  the coverage audit (`ship:audit:tests`) correlates against test names — stripping the *tags* does not weaken traceability.
- `arrange` / `act` / `assert` notes, the `Files` set, and the module `Contract`.

A de-identified scenario block keeps its title and steps and drops only its tag line, e.g.:

```
# injected as (de-identified):
Scenario: ignores a duplicate event for the same transactionId
  When the same event is delivered twice
  Then the second delivery is a no-op
```

## Keep the mapping — traceability lives in the artifact, not the code

You (the orchestrator) still hold the `SC-XX → module/test-file` mapping from `plan.md` / the spec.
Keep it for the **report / phase artifacts** so `ship:audit:tests` and humans can trace spec→test. It
belongs in markdown artifacts and Linear — never carried into a source or test identifier. Iterate
the worker over **scenarios** (one test per scenario block), not over "`@SC-XX`".
