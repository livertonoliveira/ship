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

Fields: `audit` type id · `gate`, `score` and `counts` exactly as the findings gate prints them · `top_findings` up to 5 most severe, empty if none · `report_path` relative path to the full report.

### Gate and score

Count your findings by severity, then run the script passed to you as `Findings gate script:`:

```bash
bash <findings-gate-script> --audit <type> --critical N --high N --medium N --low N
```

It applies `ship/config.md → Severity Overrides`, the gate rules and the A–F score (the tests audit's gate is capped at WARN), and prints `critical=`/`high=`/`medium=`/`low=`/`gate=`/`score=`. Use those values in the report and the JSON; never compute the gate or score yourself.

## Usage in `ship:audit:run`

After all parallel audit agents complete, their tool results are already in the orchestrator context. Extract the JSON block from each result — no need to re-open the markdown files. Pass the extracted JSON objects inline to any consolidation step.
