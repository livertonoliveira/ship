# Plan — digest-batching-decision

## Modules
### M1: Digest batching decision
- Files: src/notifications/digest-scheduler.ts, src/notifications/digest-scheduler.test.ts
- Depends on: none
- Scenarios: @SC-01
- Contract: Evaluate whether a user's pending alerts should be batched into a single digest email or delivered immediately per alert. When digest mode is enabled and the scheduled digest window has been reached, merge all pending alerts into one email and dispatch it, sending no per-alert emails. When digest mode is disabled or unavailable for the account, dispatch each pending alert as its own immediate email instead of batching.

## Integration
- M1 owns the scheduler's dispatch decision end to end; no other module wires into it.
- Register: scheduler run entrypoint invokes the batching decision directly, no separate registration point.

## Test Contract
### @SC-01 -> unit -> src/notifications/digest-scheduler.test.ts
- arrange: user has 3 pending alerts, digest mode enabled, scheduled digest window reached
- act: scheduler runs
- assert: a single email containing all 3 alerts is sent and no per-alert emails are sent
### AC-1 (unavailable outcome) -> unit -> src/notifications/digest-scheduler.test.ts (derived: no @SC)
- arrange: user has pending alerts and digest mode is disabled or unavailable for the account
- act: scheduler runs
- assert: each pending alert is sent as its own immediate email instead of a batched digest

## Coverage Gaps
- AC-1 outcome "digest mode disabled or unavailable applies immediate per-alert delivery" had no @SC scenario — derived test slot added; backfill a real scenario at spec time.

## Parallelism
- Parallel batch: M1
- Sequential: none
