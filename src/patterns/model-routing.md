# Model Routing Policy

---

## Principle

Ship pins the model per skill instead of inheriting from the session. This decouples quality
from the user's session choice: a user may pick any session model to economize across the weekly
limit, and Ship still guarantees the **reasoning tier (Sonnet)** on every skill, agent, and
dispatched sub-agent — including the orchestrators and the pure template/aggregation phases.

Ship does **not** downgrade any unit to Haiku. Earlier revisions ran template/control-flow phases
(report rendering, findings aggregation, PR expansion, one-shot config setup) on Haiku to save
cost, but thin Haiku fork-wrappers proved unreliable at *act-not-narrate dispatch*: a Haiku
wrapper in a forked context would return "completed" without actually running its Sonnet worker,
silently stranding the pipeline. To eliminate that failure mode, every unit is pinned to Sonnet.

This applies whether a skill is invoked standalone (`/ship:develop`) or as a sub-agent inside
an orchestrator (`ship:run` dispatching `develop`). Both layers reinforce each other: the
frontmatter `model:` field overrides the session tier, and an explicit `model:` parameter on
an Agent tool dispatch overrides the frontmatter.

---

## Rules

1. **Use only tier aliases** — `"sonnet"`, `"opus"`. Never use versioned IDs like
   `claude-sonnet-4-5-20250929`. Aliases resolve dynamically to the latest model in that tier,
   eliminating churn when models are upgraded. **Never pin `"haiku"`** anywhere — not in
   frontmatter, not in an Agent-tool `model:` parameter.

2. **Every skill declares `model: "sonnet"` in SKILL.md frontmatter.** No exceptions — reasoning
   phases, orchestrators, and template/aggregation phases alike. They never inherit from the
   parent session, so behavior is identical standalone or via an orchestrator.

3. **Every Agent tool dispatch passes `model: "sonnet"` explicitly.** Redundant with rule 2 (the
   sub-agent's frontmatter already pins Sonnet), but kept as a belt-and-suspenders so the dispatch
   site is self-documenting and any future agent added without `model:` in frontmatter still runs
   on Sonnet when dispatched.

---

## Phase classification

Every skill and agent runs on **Sonnet**. The table records only the role of each unit, not a
tier split (there is none).

| Skill / Phase         | Role                                            |
|-----------------------|-------------------------------------------------|
| `ship:run`            | Orchestrator — judgment dispatch: diff refresh, surgical re-run scoping, gate eval. Spawns Sonnet leaves for code/test generation. |
| `ship:develop`        | Orchestrator — slices/de-identifies per-module context, fans out `ship-develop-implement` leaves, integrates, typechecks. |
| `ship:test`           | Orchestrator — resolves/de-identifies scenarios by layer, fans out `ship-test-*` leaves. |
| `ship:init`           | Orchestrator — config-file writing + interactive Q&A. Spawns detection agents for stack/conventions. |
| `ship:audit:run`      | Orchestrator — fans out `audit:*` skills, then a consolidation agent aggregates their reports. |
| `ship:plan`           | Test-aware planning — decomposition + scenario→test mapping. |
| `ship:spec`           | Deep specification. |
| `ship:perf`           | Performance analysis. |
| `ship:security`       | Security analysis. |
| `ship:review`         | Code review. |
| `ship:analyze`        | Drift detection. |
| `ship:audit:*`        | Project-wide audits. |
| `ship:homolog`        | Interactive acceptance gate — **not forked**; runs inline in the caller's context so approval and the Done transition share one context. |
| `ship:pr`             | PR body expansion + conflict resolution + strict-mode gate eval. |
| `ship-develop-implement`, `ship-test-{unit,integration,e2e}` | Leaf workers — code / test generation. |
| `ship-audit-*`, `ship-analyze`, `ship-review`, ... | Named worker agents dispatched by the wrappers/orchestrators. |

---

## How to apply

### In SKILL.md frontmatter (every skill):

```yaml
---
name: ship:analyze
model: "sonnet"
# ... other fields
---
```

### In Agent tool calls (every dispatch):

Pass `model: "sonnet"` explicitly for every sub-agent, reasoning or aggregation alike:

```
Use the Agent tool to execute development. Pass model: "sonnet" to this agent.
```

---

## How to verify routing at runtime

Self-attestation from inside the model context is **not reliable**: the model reads its identity from the system prompt's environment block, which is templated at session start and is not necessarily rewritten when the harness switches model mid-turn (e.g., when a skill's `model:` frontmatter takes effect). A model can be executing as one tier and still report another because that is what the env block said when the session opened.

The ground truth lives in two places:

1. **`.context/ship-run/<task-id>/dispatch-log.md`** — the orchestrator's *intent*: which tool was called with which model parameter. Written by `ship:run` itself.

2. **Claude Code session JSONL** — what the harness *actually executed*. Every API response is logged with the real model ID. Path:
   ```
   ~/.claude/projects/<path-encoded>/<session-id>.jsonl
   ```
   Sub-agent transcripts live in `~/.claude/projects/<path-encoded>/<session-id>/subagents/agent-*.jsonl`.

   Quick audit of a session:
   ```bash
   jq -r '.message.model' <session-id>.jsonl | sort | uniq -c
   for f in <session-id>/subagents/agent-*.jsonl; do
     echo "== $(basename "$f") =="; jq -r '.message.model' "$f" | sort -u
   done
   ```

   Every orchestrator and sub-agent turn should resolve to a Sonnet model ID. Any Haiku turn is a routing bug.

A mismatch between dispatch-log and the JSONL is a routing bug. A mismatch between in-model self-attestation and the JSONL is **not** a routing bug — it is a known limitation of the env-block injection. Ship does not emit self-attestation banners; use dispatch-log + the session JSONL as described above to verify routing.

---

## Pattern classification (skill-patterns-convention.md)

`model-routing.md` is a **bundle pattern** (> 30 lines). Reference in SKILL.md via:

```
For model routing rules, read the file at ./ship/patterns/model-routing.md completely.
```
