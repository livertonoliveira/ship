# Model Routing Policy

---

## Principle

Ship sub-agents inherit the model tier from the parent session. Template phases (report
rendering, findings aggregation, PR expansion) run deterministic work that does not benefit
from a high-tier model. Forcing `model: "haiku"` on these phases cuts 15–30% of pipeline cost
at zero quality loss.

Reasoning phases (analysis, implementation, security scan, code review) inherit the session
tier so the user gets the quality they paid for.

---

## Rules

1. **Use only tier aliases** — `"haiku"`, `"sonnet"`, `"opus"`. Never use versioned IDs like
   `claude-haiku-4-5-20251001`. Aliases resolve dynamically to the latest model in that tier,
   eliminating churn when models are upgraded.

2. **Template phases declare `model: "haiku"` in SKILL.md frontmatter.**

3. **Reasoning phases declare no `model:` field** — they inherit from the parent session.

4. **Consolidation agents inside orchestrators** (e.g., the Step 5 agent in `ship:audit:run`)
   must pass `model: "haiku"` explicitly to the Agent tool call.

---

## Phase classification

| Skill / Phase         | Tier    | Reason                                          |
|-----------------------|---------|-------------------------------------------------|
| `ship:homolog`        | haiku   | Report rendering, findings consolidation        |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:update`         | haiku   | Config migration, file overwrite — no reasoning |
| `ship:audit:run` consolidation agent | haiku | Aggregates pre-structured audit reports |
| `ship:develop`        | session | Implementation — needs full reasoning           |
| `ship:test`           | session | Test generation — needs full reasoning          |
| `ship:perf`           | session | Performance analysis — needs full reasoning     |
| `ship:security`       | session | Security analysis — needs full reasoning        |
| `ship:review`         | session | Code review — needs full reasoning              |
| `ship:analyze`        | session | Drift detection — needs full reasoning          |
| `ship:spec`           | session | Deep specification — needs full reasoning       |
| `ship:audit:*`        | session | Project-wide audits — needs full reasoning      |

---

## How to apply

### In SKILL.md frontmatter (for skills that are themselves template phases):

```yaml
---
name: ship:homolog
model: "haiku"
# ... other fields
---
```

### In Agent tool calls (for orchestrators launching consolidation sub-agents):

Pass `model: "haiku"` when calling the Agent tool for consolidation work:

```
Use the Agent tool to consolidate results. Pass model: "haiku" to this agent —
it performs template/report aggregation, not reasoning.
```

---

## Pattern classification (skill-patterns-convention.md)

`model-routing.md` is a **bundle pattern** (> 30 lines). Reference in SKILL.md via:

```
For model routing rules, read the file at ./ship/patterns/model-routing.md completely.
```
