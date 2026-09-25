# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports (homolog, pr, and the pipeline's gate presentation).

The gate index is the per-phase row that `pipeline.sh rows` prints (the caller already has it in context); never re-derive "most recent row per phase" from `phase-status.md` by hand.

---

## Algorithm

For each phase (perf, security, review):

1. **Look up the gate** from that phase's row in the gate index.
   - If the phase has no row: treat as `FAIL` (safe default)
2. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do **NOT** open the findings markdown:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Open the findings markdown file for this phase, then filter before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (homolog posts it after approval), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`
