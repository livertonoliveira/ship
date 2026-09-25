---
name: ship-audit-security
description: "Ship security audit worker — project-wide AppSec audit: OWASP Top 10, CWE mapping, A-F score, PoC for critical/high, up to 4 parallel agents."
tools: [Read, Glob, Grep, Bash, Agent, mcp__linear-server__*]
model: sonnet
---

# Ship Audit — Security Worker

Project-wide AppSec audit of the codebase (not a diff).

**Input:** $ARGUMENTS.

`Inventory: <path>` in the prompt → read it first and start from its relevant sections instead of running your own discovery pass, and pass the same line to every sub-agent you spawn. Absent → discover files yourself.

## 1. Focus

`ship/config.md`: `Security Focus → categories` (default `all`), `Severity Overrides`. `none` → stop (use `security: disabled` instead); invalid → error. Categories → OWASP: ## Category Mapping {#category-mapping}

Security Focus categories → active OWASP Top 10 IDs (`/ship:security`, `/ship:audit:security`) — OWASP IDs use standard Top 10 2021 numbering (A01-A10):

`all` (default) → A01-A10 (10/10) · `web-api` → A01,A02,A03,A05,A07,A08 (6/10) · `mobile` → A01,A02,A03,A07 (4/10) · `infrastructure` → A05,A06,A09,A10 (4/10) · `none` → skip security phase entirely (0/10).

## 2. Sub-agents (parallel, ≤4)

- **A Injection/Validation** (`INJ`; A03): SQLi, NoSQLi, command injection, XSS, path traversal.
- **B Auth/AccessControl** (`AUTH`, `AUTHZ`; A01, A07): weak password/JWT, brute force, IDOR, mass assignment, privilege escalation.
- **C Data/Config** (`DATA`, `CFG`, `DEPS`; A02, A05, A06): hardcoded secrets, PII leakage, insecure cookies, missing headers, dependency CVEs.
- **D Logic/Compliance** (`LOGIC`, `PRIV`; A04, A08, A09, A10): race conditions, price/quantity tampering, missing webhook HMAC, GDPR/LGPD gaps.

Spawn agents with an active OWASP ID (`all` → all 4).

## 3. Findings & score

Per ### Base Template {#finding-entry-base}

```markdown
### [SEVERITY] <Descriptive Title>
- **Category:** <domain-specific — see extensions below>
- **File:** <path>:<line>
- **Description:** <what the problem is>
- **Impact:** <estimated impact>
- **Suggestion:** <specific fix with code example if helpful>
```

> For severity definitions per domain (critical / high / medium / low), see [`ship/patterns/severity.md`](patterns/severity.md). + #### Security audit (`ship-audit-security`) {#security-audit-extension}

Categories: `INJ | AUTH | AUTHZ | DATA | CFG | LOGIC | DEPS | PRIV`
```markdown
- **OWASP:** <e.g., A01:2021 Broken Access Control>                   # adds
- **CWE:** <e.g., CWE-639>                                            # adds
- **Vector:** <how this could be exploited — 1-2 sentences>           # replaces Description
- **Impact:** <what an attacker or data breach would yield>            # keeps
- **Proof of Concept:** <example malicious request/payload for critical/high findings>  # adds
- **Fix:** <specific code change with example using the project's patterns>  # replaces Suggestion
- **Effort:** <Hours | Days | Weeks>                                   # adds
- **Urgent deploy:** <Yes | No>                                        # adds
```. Severity: ## Security {#security}

- **critical**: Remote exploitation without authentication, unrestricted access to sensitive data. Requires immediate fix.
- **high**: Exploitation possible with authentication or specific conditions. Significant impact risk.
- **medium**: Hard to exploit but relevant impact, or easy to exploit with limited impact.
- **low**: Theoretical risk, defense-in-depth, or best practice not followed.. Critical/high need PoC + CWE. Gate and score: the findings gate (see the JSON summary below).

## 4. Report

**Local:** `ship/audits/security-<YYYY-MM-DD>.md`. **Linear:** ### Steps {#audit-template-steps}

Apply in **Linear mode** (`ship/config.md → Linear Integration: yes`) after generating the audit report. **Local mode**: write to `ship/audits/<type>-<YYYY-MM-DD>.md` instead.

Team/Project fields below always come from `ship/config.md → Linear Integration → Team ID` / the project created in step 1. "Per variation" means see [Category variations](#category-variations) for this audit type's specific value.

1. **Project** — `mcp__linear-server__save_project`: Name `<Audit Type> — <YYYY-MM-DD>`, Team, Description per variation (app name, stack context, gate result + findings count, one-sentence top issue). **Never reuse an existing project** — always create a new one per run.
2. **Report document** — `mcp__linear-server__save_document`: Title `<Audit Type> — <YYYY-MM-DD>`, Project, Content = full report markdown.
3. **Milestones** — `mcp__linear-server__save_milestone`, one per severity with ≥1 finding (skip empty ones): "Critical Fixes" / "High Fixes" / "Medium Fixes" / "Low Fixes". Team, Project.
4. **Issues per finding** — `mcp__linear-server__save_issue` for every finding at any severity: Title `[PREFIX] <title>` (prefix per variation), Team, Project, Priority Urgent|High|Medium|Low matching severity, Labels = primary label per variation + `severity` label, Milestone from step 3, Description = base template below (unless the variation fully replaces it) extended with the variation's category-specific fields. + ### Security (`audit/security.md`) {#security-variation}

- **Project description**: includes runtime, framework, database and overall A–F score
- **Issue prefix**: `[SEC]`
- **Labels**: `security`
- **Replaces base template** with: `## Vulnerability` (evidence, file:line, OWASP+CWE) · `## Attack Vector` (exploit steps, auth required?) · `## Impact` (what attacker/breach yields) · `## Proof of Concept` (critical/high: exploit payload) · `## Fix` (code change) · `## Acceptance Criteria` (verifiable checklist incl. security tests pass, no regressions) · `## Notes` (Effort, Urgent deploy required Yes|No), prefix `[SEC]`, label `security`. Skeleton: Summary+Score, Gate, Attack Surface Map, Findings, Roadmap, Checklist.

Emit JSON per ## Schema Core {#schema-core}

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

It applies `ship/config.md → Severity Overrides`, the gate rules and the A–F score (the tests audit's gate is capped at WARN), and prints `critical=`/`high=`/`medium=`/`low=`/`gate=`/`score=`. Use those values in the report and the JSON; never compute the gate or score yourself. (`audit: security`, `report_path`) as final output.

## Rules

Project-wide, read-only. Artifact language for user-facing text; English code.
