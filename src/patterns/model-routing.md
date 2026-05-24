# Model Routing Policy

---

## Principle

Ship pins the model per skill instead of inheriting from the session. This decouples cost
control from quality: users can pick Haiku as their session model to economize across the
weekly limit, and Ship still guarantees Sonnet on the skills that actually reason (implementation,
analysis, generation, correlation). Symmetrically, template/control-flow skills (report
rendering, findings aggregation, PR expansion, orchestration) are pinned to Haiku because they
gain nothing from a higher tier.

This applies whether a skill is invoked standalone (`/ship:develop`) or as a sub-agent inside
an orchestrator (`ship:run` dispatching `develop`). Both layers reinforce each other: the
frontmatter `model:` field overrides the session tier, and an explicit `model:` parameter on
an Agent tool dispatch overrides the frontmatter.

---

## Rules

1. **Use only tier aliases** — `"haiku"`, `"sonnet"`, `"opus"`. Never use versioned IDs like
   `claude-haiku-4-5-20251001`. Aliases resolve dynamically to the latest model in that tier,
   eliminating churn when models are upgraded.

2. **Template phases declare `model: "haiku"` in SKILL.md frontmatter.**

3. **Reasoning phases declare `model: "sonnet"` in SKILL.md frontmatter.** They never inherit
   from the parent session — Sonnet is pinned so the skill behaves identically whether invoked
   standalone or via an orchestrator. Reasoning phases include: `develop`, `test`, `perf`,
   `security`, `review`, `analyze`, `spec`, and all `audit:*` skills except `audit:run`.

4. **Reasoning agents launched by Haiku orchestrators must pass `model: "sonnet"` explicitly**
   to the Agent tool call. Redundant with rule 3 (the frontmatter would already pin Sonnet),
   but kept as a belt-and-suspenders so the dispatch site is self-documenting and any future
   reasoning skill added without `model: "sonnet"` in frontmatter still runs on Sonnet when
   dispatched. The symmetric rule also holds: **consolidation/template agents inside Sonnet
   contexts** (e.g., the Step 5 agent in `ship:audit:run`) must pass `model: "haiku"` explicitly.

---

## Phase classification

| Skill / Phase         | Tier    | Reason                                          |
|-----------------------|---------|-------------------------------------------------|
| `ship:homolog`        | haiku   | Report rendering, findings consolidation        |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:run`            | haiku (orchestrator) | Template/control-flow: file reads, deterministic diff classification, gate eval, dispatch. Spawns Sonnet agents explicitly for reasoning phases. |
| `ship:init`           | haiku (orchestrator) | Config-file template writing + interactive Q&A. Spawns Sonnet agents explicitly for stack/conventions detection. |
| `ship:audit:run` consolidation agent | haiku | Aggregates pre-structured audit reports |
| `ship:develop`        | sonnet   | Implementation — needs full reasoning           |
| `ship:test`           | sonnet   | Test generation — needs full reasoning          |
| `ship:perf`           | sonnet   | Performance analysis — needs full reasoning     |
| `ship:security`       | sonnet   | Security analysis — needs full reasoning        |
| `ship:review`         | sonnet   | Code review — needs full reasoning              |
| `ship:analyze`        | sonnet   | Drift detection — needs full reasoning          |
| `ship:spec`           | sonnet   | Deep specification — needs full reasoning       |
| `ship:audit:*`        | sonnet   | Project-wide audits — needs full reasoning      |

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
