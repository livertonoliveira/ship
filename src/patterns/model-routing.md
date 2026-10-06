# Model Routing Policy

---

## Principle

Ship pins the model per skill instead of inheriting from the session. This decouples quality
and cost from the user's session choice: planning runs on **Opus** (`ship:plan`, `ship:spec`),
and everything else — orchestration, implementation, verification — on **Sonnet**, whatever
model the session was opened with.

**A `model:` on a skill that is not forked lasts one turn.** The session model resumes on the next
prompt, and every `<task-notification>` from a background worker starts a new one. Measured on
677 graph nodes: `ship:run` declared Sonnet and every node still orchestrated on the session's
Opus — 69% of a node's cost. So the multi-turn orchestrators run forked (`context: fork`,
`background: false`), where the frontmatter model is the subagent's model for the whole run:
`ship:run` and `ship:graph`. Graph nodes are also launched on the orchestration model
(`driver-orca.sh` passes `--model`, `SHIP_NODE_MODEL` overrides, default `sonnet`).

Ship never pins `haiku`: forked wrappers must reliably dispatch their workers, so every unit runs on Sonnet.

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

2. **Every skill declares `model:` in SKILL.md frontmatter** — `"opus"` for planning
   (`ship:plan`, `ship:spec`), `"sonnet"` for every other skill. A skill whose work spans turns
   must also be forked, or the declaration only holds for its first turn.

3. **Every Agent tool dispatch passes `model: "sonnet"` explicitly.** Redundant with rule 2 (the
   sub-agent's frontmatter already pins Sonnet), but kept as a belt-and-suspenders so the dispatch
   site is self-documenting and any future agent added without `model:` in frontmatter still runs
   on Sonnet when dispatched.

---

## Phase classification

Every skill and agent runs on **Sonnet** except planning (`ship:plan`, `ship:spec`), which runs on **Opus**.

| Skill / Phase         | Role                                            |
|-----------------------|-------------------------------------------------|
| `ship:run`            | Executor of `pipeline.sh next`, forked on Sonnet — dispatches exactly what the state machine prints; ordering, scoping and gating live in the script. |
| `ship:graph`          | Executor of `graph.sh next`, forked on Sonnet. |
| `ship:develop`        | Direct implementer — writes all modules sequentially in dependency order in one context, integrates, typechecks. |
| `ship:test`           | Orchestrator — resolves/de-identifies scenarios by layer, fans out `ship-test-*` leaves. |
| `ship:init`           | Orchestrator — config-file writing + interactive Q&A. Spawns detection agents for stack/conventions. |
| `ship:audit:run`      | Orchestrator — fans out `audit:*` skills and applies the consolidated gate from their JSON summaries in its own context. |
| `ship:plan`           | Test-aware planning — decomposition + scenario→test mapping (Opus). |
| `ship:spec`           | Deep specification (Opus). |
| `ship:perf`           | Performance analysis. |
| `ship:security`       | Security analysis. |
| `ship:review`         | Code review. |
| `ship:audit:*`        | Project-wide audits. |
| `ship:homolog`        | Interactive acceptance gate — **not forked**; runs inline in the caller's context so approval and the Done transition share one context. |
| `ship:pr`             | PR body expansion + conflict resolution + strict-mode gate eval. |
| `ship-test-{unit,integration,e2e}` | Leaf workers — test generation. |
| `ship-audit-*`, `ship-review`, `ship-perf`, ... | Named worker agents dispatched by the wrappers/orchestrators. |

---

## How to apply

### In SKILL.md frontmatter (every skill):

```yaml
---
name: ship:review
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

1. **`.context/ship-run/<task-id>/dispatch-log.md`** — the pipeline's *intent*: which tool was dispatched with which model parameter. Written by `pipeline.sh`.

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

   Every orchestrator and sub-agent turn should resolve to a Sonnet model ID, and `ship:plan` to an Opus one. Any Haiku turn is a routing bug.

A mismatch between dispatch-log and the JSONL is a routing bug. A mismatch between in-model self-attestation and the JSONL is **not** a routing bug — it is a known limitation of the env-block injection. Ship does not emit self-attestation banners; use dispatch-log + the session JSONL as described above to verify routing.
