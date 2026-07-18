# Audit Summary Schema

## Schema Core {#schema-core}

Each `ship:audit:*` agent outputs this JSON as the **last content** of its tool result (`ship:audit:run` reads it directly — no file I/O).

### Schema

```json
{
  "audit": "<backend|frontend|database|security|tests>",
  "gate": "<PASS|WARN|FAIL>",
  "score": "<A|B|C|D|F>",
  "counts": { "critical": 0, "high": 0, "medium": 0, "low": 0 },
  "top_findings": [{ "id": "<FINDING-ID>", "severity": "<critical|high|medium|low>", "title": "<short title>", "file": "<path/to/file.ts:line>" }],
  "report_path": "ship/audits/<type>-<YYYY-MM-DD>.md"
}
```

Fields: `audit` type id · `gate` per `@ship/patterns/gates.md#gate-decision-rules` · `score` per Scoring table below · `counts` findings by severity · `top_findings` up to 5 most severe, empty if none · `report_path` relative path to the full report.

### Scoring table

`A` none/only-low · `B` no critical/high, ≥1 medium · `C` no critical, 1–2 high · `D` no critical, 3+ high · `F` ≥1 critical.

## Audit-specific notes

| Audit | Gate cap | Notes |
|-------|----------|-------|
| `backend` | PASS\|WARN\|FAIL | Standard gate |
| `frontend` | PASS\|WARN\|FAIL | Standard gate |
| `database` | PASS\|WARN\|FAIL | Standard gate |
| `security` | PASS\|WARN\|FAIL | Standard gate |
| `tests` | **PASS\|WARN** | HIGH findings map to WARN, not FAIL — test gaps are a quality issue, not blocking |

## Usage in `ship:audit:run`

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step.
