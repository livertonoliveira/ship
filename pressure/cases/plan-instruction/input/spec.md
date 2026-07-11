## Context

Notification digests batch a user's pending alerts into a single email sent on a fixed schedule, instead of emailing each alert as it fires. The digest scheduler already exists; this feature adds the batching decision itself.

## Acceptance Criteria

### AC-1: Digest batching decision

Given a user has pending alerts and digest mode is enabled for their account, when the scheduler runs, the system evaluates whether batching applies: reaching the scheduled digest window applies batched delivery (all pending alerts merged into one email); digest mode being disabled or unavailable for the account applies immediate per-alert delivery instead.

## Scenarios

```gherkin
@SC-01 @unit
Scenario: Pending alerts are merged into a single digest email at the scheduled window
  Given a user has 3 pending alerts and digest mode enabled
  And the scheduled digest window has been reached
  When the scheduler runs
  Then a single email containing all 3 alerts is sent
  And no per-alert emails are sent
```

## Files

- `src/notifications/digest-scheduler.ts` — evaluates the batching decision and dispatches the digest or immediate email
- `src/notifications/digest-scheduler.test.ts` — covers the scheduler's dispatch behavior
