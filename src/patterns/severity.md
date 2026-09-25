# Severity Definitions

## Performance {#performance}

- **critical**: Will cause visible performance degradation in production (e.g., N+1 on every request, full table scan on large table)
- **high**: Likely to cause issues under load (e.g., missing pagination on growing dataset)
- **medium**: Suboptimal but will not cause immediate issues (e.g., missing cache on moderately accessed data)
- **low**: Best practice not followed, marginal impact (e.g., synchronous logging in low-traffic endpoint)

## Security {#security}

- **critical**: Remote exploitation without authentication, unrestricted access to sensitive data. Requires immediate fix.
- **high**: Exploitation possible with authentication or specific conditions. Significant impact risk.
- **medium**: Hard to exploit but relevant impact, or easy to exploit with limited impact.
- **low**: Theoretical risk, defense-in-depth, or best practice not followed.

## Code Review {#code-review}

- **critical**: Architectural issue that will cause significant problems if not addressed (e.g., circular dependency, broken abstraction that leaks implementation details across the entire system)
- **high**: Significant design issue that will make the code hard to maintain/extend (e.g., god class, tight coupling between modules)
- **medium**: Code smell that should be addressed but does not block (e.g., duplicated logic, overly complex conditional)
- **low**: Minor improvement opportunity (e.g., naming could be clearer, slightly long function)

## Frontend {#frontend}

Core Web Vitals thresholds (Good / Needs Improvement / Poor): LCP ≤2.5s / 2.5-4.0s / >4.0s · INP ≤200ms / 200-500ms / >500ms · CLS ≤0.1 / 0.1-0.25 / >0.25 · FCP ≤1.8s / 1.8-3.0s / >3.0s · TTFB ≤800ms / 800-1800ms / >1800ms.

- **critical**: Vital in "Poor" range, severe UX/conversion impact · **high**: "Needs Improvement", measurable impact · **medium**: relevant inefficiency, no immediate impact · **low**: incremental, backlog

## Database {#database}

- **critical**: Causes active production degradation, data risk, or imminent failure as data grows
- **high**: Significant performance degradation that worsens with data growth
- **medium**: Relevant inefficiency, no immediate critical impact
- **low**: Best practice not followed, marginal impact

## No override markers {#no-markers}

> Ship never emits spec-ID comments (`IMPL-REQ-XX`, `IMPL-SC-XX`, `TEST-REQ-XX`, `TEST-AC-XX`, `TEST-SC-XX`) into source or test files, so the coverage analyzer (`ship:audit:tests`, keyword-based Jaccard correlation) never scans for them. When requirement names don't match code naming (e.g., spec says "cache invalidation" but code uses "eviction"), the item surfaces as **uncertain** — the fix is to rename the code/test to match the spec vocabulary, never to annotate it with a marker comment.

## Severity Overrides

`ship/config.md` may remap a phase's severities before the gate:

```
## Severity Overrides
- perf: high→medium
- security: medium→low
```

`<phase>` is one of `dev`, `test`, `perf`, `security`, `review`, `frontend-perf`, `database`, `backend`. `findings-gate.sh` and `pipeline.sh gate` apply the overrides and reject an unknown phase — never tally them yourself.
