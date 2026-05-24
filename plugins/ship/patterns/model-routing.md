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

4. **Reasoning agents launched by Haiku orchestrators must pass `model: "sonnet"` explicitly**
   to the Agent tool call. This applies to every dispatch inside `ship:run` (develop, test,
   perf, security, review, fix, analyze) and `ship:init` (stack/conventions detection). The
   symmetric rule also holds: **consolidation/template agents inside Sonnet contexts** (e.g.,
   the Step 5 agent in `ship:audit:run`) must pass `model: "haiku"` explicitly.

---

## Phase classification

| Skill / Phase         | Tier    | Reason                                          |
|-----------------------|---------|-------------------------------------------------|
| `ship:homolog`        | haiku   | Report rendering, findings consolidation        |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:update`         | haiku   | Config migration, file overwrite — no reasoning |
| `ship:run`            | haiku (orchestrator) | Template/control-flow: file reads, deterministic diff classification, gate eval, dispatch. Spawns Sonnet agents explicitly for reasoning phases. |
| `ship:init`           | haiku (orchestrator) | Config-file template writing + interactive Q&A. Spawns Sonnet agents explicitly for stack/conventions detection. |
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

## Orchestrator-on-Haiku pattern

When a skill is mostly **control-flow and dispatch** — reading files, running deterministic
bash for classification, evaluating gates, spawning sub-agents, aggregating results — its body
gains nothing from a session-tier model. The expensive reasoning lives inside the sub-agents.

For these skills, apply the **Orchestrator-on-Haiku pattern**:

1. Set the skill's frontmatter to `model: "haiku"`.
2. In every Agent tool dispatch inside the skill, pass `model: "sonnet"` explicitly for any
   sub-agent that does reasoning work (implementation, analysis, generation, correlation).
3. Sub-agents that themselves do template/aggregation work inherit Haiku from the parent — no
   explicit model parameter needed (e.g., `homolog` dispatched by `run` keeps Haiku because
   its own SKILL.md frontmatter already declares `model: "haiku"`).

**Boundary**: only apply this pattern when the orchestrator's body is genuinely deterministic.
If the orchestrator itself needs to make non-trivial judgment calls (e.g., dependency inference,
ambiguous classification), either keep it at session tier or rewrite the judgment as a
deterministic rule before downgrading. See the multi-task note in `ship:run` for an example
mitigation (dependency inference removed in favor of deterministic Linear milestone order).

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

### In Agent tool calls (Haiku orchestrator launching reasoning sub-agents):

Pass `model: "sonnet"` when calling the Agent tool for reasoning work:

```
Use the Agent tool to execute development. Pass model: "sonnet" to this agent —
implementation requires full reasoning.
```

### In Agent tool calls (Sonnet orchestrator launching consolidation sub-agents):

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
