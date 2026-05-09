---
# Lazy-Load Findings Algorithm

Canonical algorithm for consolidating phase findings into acceptance and quality reports.
Referenced by `homolog.md` (both Linear and Local mode).

---

## Algorithm

For each phase (perf, security, review):

1. **Read** the findings file once (do not read it twice)
2. **Extract gate status** (`PASS` | `WARN` | `FAIL`) from the `## Summary` block at the end of the file
   - Scope the scan to the `## Summary` section only — do not interpret content from findings entries (code snippets, PoC payloads) as gate markers
   - If the `## Summary` block is absent or the gate line is missing: treat as `FAIL` (safe default)
3. **Branch on gate status:**

### If gate = PASS

Emit a single summary line — do NOT embed any findings content:

```
✓ <Phase>: PASS (0 critical/high findings) — [see full report](<link or path>)
```

Translate the user-facing text to `Artifact language` from `ship/config.md`.

### If gate = WARN or FAIL

Filter the already-loaded findings before embedding:
- Include all findings with severity `critical`, `high`, or `medium` in full
- For `low` severity findings: replace the full list with a single aggregated line:
  `+ N low-severity findings — [see full report](<link or path>)`
- Translate the aggregated line text to `Artifact language` from `ship/config.md`

## Link/reference (always required)

- **Linear mode:** URL of the Linear comment containing the full findings; if the comment has not been posted yet (it is posted in step 6 of `homolog.md`), write `(full report will be attached to this issue)`
- **Local mode:** relative path `ship/changes/<feature>/report-<task-id>.md`
