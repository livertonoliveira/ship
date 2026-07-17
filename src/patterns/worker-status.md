# Worker Status Pattern

Completion-state rules applied to every leaf worker dispatched by an orchestrator (`ship:develop`, `ship:run`, and any other command that fans out to Agents).

This is a **completion axis** — it answers "did the worker finish, and how?" — and is orthogonal to the **quality axis** documented in `gates.md` (PASS/WARN/FAIL, derived from `critical`/`high`/`medium` findings). A worker can report `Status: DONE` while its output still triggers `Gate: FAIL` in a later quality phase — the two axes are evaluated independently and never conflated.

Each worker writes its completion state as a single line in `phase-status-<phase>.md`:

```
Status: <ENUM>
```

## Enum

Exactly four states. No fifth state exists.

### DONE

**Trigger:** the worker completed its assigned unit with no caveats.

**Behavior:** orchestrator marks the unit complete and continues to the next unit or phase.

### DONE_WITH_CONCERNS

**Trigger:** the worker completed its assigned unit but hit a non-blocking caveat (e.g. a collision with a denylisted path, a partial fallback applied).

**Behavior:** orchestrator marks the unit complete, records a `warn` entry describing the caveat, and continues.

### NEEDS_CONTEXT

**Trigger:** the worker could not complete its unit because required context or input was missing (e.g. an ambiguous contract, a referenced file that does not exist).

**Behavior:** orchestrator re-dispatches the worker with the missing context supplied, bounded by the existing retry ceilings for the calling command (`ship:develop`: 2 cycles; `ship:run`: 3 iterations). If the ceiling is reached without resolution, treat as `BLOCKED`.

### BLOCKED

**Trigger:** the worker determined the unit is not viable in its current state (e.g. the plan is unworkable, a hard dependency is absent, sibling file ownership conflicts).

**Behavior:** orchestrator stops dispatching further units in the affected chain and escalates via the calling command's `on_fail` configuration.

## Fail-closed rule

A `Status:` field that is **missing**, **empty**, or **outside the four-value enum** is always treated as `BLOCKED`. The orchestrator never guesses intent from partial or malformed status output — absence or ambiguity is the least permissive outcome, not the most permissive.

## Edge cases

### Edge case 1 — Missing `Status:` field

**Trigger:** the worker's output has no `Status:` line at all.

**Behavior:** treat as `BLOCKED` per the fail-closed rule. Escalate via `on_fail`.

### Edge case 2 — Out-of-enum value

**Trigger:** the `Status:` line contains a value other than `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED` (e.g. a typo, a legacy value, free text).

**Behavior:** treat as `BLOCKED` per the fail-closed rule. Escalate via `on_fail`.

### Edge case 3 — Empty value

**Trigger:** the `Status:` line is present but has no value after the colon.

**Behavior:** treat as `BLOCKED` per the fail-closed rule. Escalate via `on_fail`.

### Edge case 4 — `DONE` with a failing quality gate

**Trigger:** a worker reports `Status: DONE` and a later quality phase reports `Gate: FAIL` on the same unit's output.

**Behavior:** both are valid simultaneously. The completion axis (`DONE`) and the quality axis (`Gate: FAIL`) are independent signals; the orchestrator handles each per its own rules — completion status does not suppress or override gate behavior, and gate behavior does not rewrite completion status.
