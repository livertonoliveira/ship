# Plan — digest-scheduler

## Modules
### M1: Digest scheduler batching decision
- Files: src/notifications/digest-scheduler.ts, src/notifications/digest-scheduler.test.ts
- Depends on: none
- Scenarios: @SC-01
- Contract: evaluate whether the scheduled digest window has been reached for a user with digest mode enabled and pending alerts; when reached, merge all pending alerts into a single digest email and suppress per-alert emails.

## Integration
- Register: digest scheduler is invoked directly by the existing notification dispatch entry point.

## Test Contract
### @SC-01 -> unit -> src/notifications/digest-scheduler.test.ts
- arrange: a user has 3 pending alerts and digest mode enabled
- act: the scheduled digest window has been reached and the scheduler runs
- assert: a single email containing all 3 alerts is sent and no per-alert emails are sent

## Parallelism
- Single module: M1 (no parallel batches)
