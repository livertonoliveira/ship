# Worker Status Pattern

Completion-state rules applied to every leaf worker dispatched by an orchestrator (`ship:test`, `ship:run`, and any other command that fans out to Agents).

This is a **completion axis** — it answers "did the worker finish, and how?" — and is orthogonal to the **quality axis** documented in `gates.md` (PASS/WARN/FAIL, derived from `critical`/`high`/`medium` findings). A worker can report `Status: DONE` while its output still triggers `Gate: FAIL` in a later quality phase — the two axes are evaluated independently and never conflated.

## Enum {#worker-status-contract}

Each worker ends its report with a single line — and, when the prompt names a status file, writes the same line there:

```
Status: <ENUM>
```

Exactly four states. No fifth state exists.

### DONE

**Trigger:** the worker completed its assigned unit with no caveats.

**Behavior:** the unit is complete; nothing is recorded.

### DONE_WITH_CONCERNS

**Trigger:** the worker completed its assigned unit but hit a non-blocking caveat (e.g. a collision with a denylisted path, a partial fallback applied).

**Behavior:** the unit is complete; describe the caveat in the report. The status is recorded, not gated.

### NEEDS_CONTEXT

**Trigger:** the worker could not complete its unit because required context or input was missing (e.g. an ambiguous contract, a referenced file that does not exist).

**Behavior:** name the missing input in the report. The status is recorded, not gated; a standalone `ship:test` run may re-dispatch with the input supplied.

### BLOCKED

**Trigger:** the worker determined the unit is not viable in its current state (e.g. the plan is unworkable, a hard dependency is absent, sibling file ownership conflicts).

**Behavior:** say why in the report. The status is recorded, not gated.

## Where the status goes

Inside `/ship:run`, `pipeline.sh` reads each test worker's status file through `worker-status-gate.sh` when it consolidates the manifests, and names every layer that did not report `DONE` in the `test-generate` row's Notes (`worker status: e2e NEEDS_CONTEXT`), which the quality report shows. It never changes the gate: `NEEDS_CONTEXT` is the normal answer of an e2e layer with no framework.

## Fail-closed rule

A `Status:` field that is **missing**, **empty**, or **outside the four-value enum** is always treated as `BLOCKED`. The orchestrator never guesses intent from partial or malformed status output — absence or ambiguity is the least permissive outcome, not the most permissive.

## Edge cases

### Edge case 1 — Missing `Status:` field

**Trigger:** the worker's output has no `Status:` line at all.

**Behavior:** treat as `BLOCKED` per the fail-closed rule.

### Edge case 2 — Out-of-enum value

**Trigger:** the `Status:` line contains a value other than `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED` (e.g. a typo, a legacy value, free text).

**Behavior:** treat as `BLOCKED` per the fail-closed rule.

### Edge case 3 — Empty value

**Trigger:** the `Status:` line is present but has no value after the colon.

**Behavior:** treat as `BLOCKED` per the fail-closed rule.

### Edge case 4 — `DONE` with a failing quality gate

**Trigger:** a worker reports `Status: DONE` and a later quality phase reports `Gate: FAIL` on the same unit's output.

**Behavior:** both are valid simultaneously. The completion axis (`DONE`) and the quality axis (`Gate: FAIL`) are independent signals; the orchestrator handles each per its own rules — completion status does not suppress or override gate behavior, and gate behavior does not rewrite completion status.
