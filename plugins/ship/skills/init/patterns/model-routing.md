# Model Routing Policy

---

## Principle

Ship pins the model per skill instead of inheriting from the session. This decouples cost
control from quality: users can pick Haiku as their session model to economize across the
weekly limit, and Ship still guarantees Sonnet on the skills that actually reason (implementation,
analysis, generation, correlation). Symmetrically, pure template/control-flow skills (report
rendering, findings aggregation, PR expansion, one-shot config setup) are pinned to Haiku because
they gain nothing from a higher tier. Judgment-heavy orchestrators (`run`, `develop`, `test`) stay
on the reasoning tier even though they also dispatch — see the Boundary rule.

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

3. **Reasoning units declare `model: "sonnet"` in frontmatter.** They never inherit from the
   parent session — Sonnet is pinned so behavior is identical standalone or via an orchestrator.
   Sonnet reasoning lives in the `plan`, `perf`, `security`, `review`, `analyze`, `spec` skills
   and all `audit:*` skills except `audit:run`; plus the leaf workers `ship-develop-implement`
   and `ship-test-{unit,integration,e2e}`. The `develop` and `test` **orchestrators are also Sonnet**:
   although `plan` front-loads the heavy decomposition, their bodies still make non-trivial judgment
   calls — slicing per-module/per-layer context, **de-identifying** it before injection, dependency
   ordering, integration checks — and must reliably dispatch rather than narrate. Per the Boundary
   rule (below), that keeps them at the reasoning tier rather than pinning Haiku. They still fan out
   Sonnet leaves for the actual code/test generation.

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
| `ship:homolog`        | haiku   | Report rendering + findings consolidation. **Not forked** — interactive acceptance gate; runs inline so approval and the Done transition share one context (see `ship:init`/`ship:pr`). |
| `ship:pr`             | haiku   | PR body template expansion (tradeoff: conflict resolution and strict-mode audit gate eval use the same tier; accepted for cost efficiency — upgrade to session if quality regressions are observed) |
| `ship:run`            | sonnet (orchestrator) | Judgment dispatch: although much of the body is control-flow (file reads, deterministic diff classification, gate eval, dispatch), the working-tree diff refresh, surgical re-run scoping, and gate decisions proved to need reliable multi-step instruction-following that Haiku fumbled in practice (e.g. corrupting `diff.md` / staged-vs-unstaged confusion). Pinned to the reasoning tier per the Boundary rule. Still spawns Sonnet leaves for code/test generation. |
| `ship:init`           | haiku (orchestrator) | Config-file template writing + interactive Q&A. Spawns Sonnet agents explicitly for stack/conventions detection. |
| `ship:audit:run` consolidation agent | haiku | Aggregates pre-structured audit reports |
| `ship:plan`           | sonnet   | Test-aware planning — decomposition + scenario→test mapping needs full reasoning |
| `ship:develop`        | sonnet (orchestrator) | Judgment dispatch: slices/de-identifies per-module context, fans out Sonnet `ship-develop-implement` leaves, integrates, typechecks. Kept at reasoning tier per the Boundary rule. |
| `ship:test`           | sonnet (orchestrator) | Judgment dispatch: resolves/de-identifies scenarios by layer, fans out Sonnet `ship-test-*` leaves. Kept at reasoning tier per the Boundary rule. |
| `ship-develop-implement`, `ship-test-{unit,integration,e2e}` | sonnet (leaf) | Code / test generation — needs full reasoning |
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
3. Sub-agents dispatched by an orchestrator run at the tier their own SKILL.md frontmatter
   declares, not the parent's — e.g. `run` (Haiku) dispatches `develop`/`test`, which run on Sonnet
   because their frontmatter declares `model: "sonnet"` (they are judgment orchestrators, not pure
   template phases — see the Boundary note). Pure template/aggregation sub-agents that declare or
   inherit Haiku stay on Haiku. Note: `homolog` is the exception among the Haiku phases — it is
   **not** forked (it is an interactive gate), so it runs inline in the caller's context rather than
   as a sub-agent.

**Boundary**: only apply this pattern when the orchestrator's body is genuinely deterministic.
If the orchestrator itself needs to make non-trivial judgment calls (e.g., dependency inference,
ambiguous classification, context de-identification, reliable act-not-narrate dispatch), do NOT
pin Haiku — either pin the reasoning tier (`model: "sonnet"`, as `develop`/`test` do) or rewrite
the judgment as a deterministic rule before downgrading. `ship:run` was originally pinned Haiku via
the latter route, but observed runs showed its diff-refresh, surgical re-run scoping, and gate
decisions still demanded reliable multi-step judgment Haiku did not deliver consistently — so it is
now pinned `model: "sonnet"`. It keeps its deterministic guardrails regardless (exact diff-capture
command + unified-diff assertion; deterministic Linear milestone ordering with no dependency
inference). The remaining Haiku orchestrators (`homolog`, `pr`, `init`, `audit:run` consolidation)
stay Haiku because their bodies are genuinely template/aggregation; revisit individually if a
quality regression is observed (e.g. `pr` conflict resolution / strict-mode gate eval).

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

## How to verify routing at runtime

Self-attestation from inside the model context is **not reliable**: the model reads its identity from the system prompt's environment block, which is templated at session start and is not necessarily rewritten when the harness switches model mid-turn (e.g., when a skill's `model:` frontmatter takes effect). A model can be executing as Haiku and still report Opus because that is what the env block said when the session opened.

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

   If the orchestrator turns are split between session model and Haiku, the override is working. If they are 100% session model, routing failed.

A mismatch between dispatch-log and the JSONL is a routing bug. A mismatch between in-model self-attestation and the JSONL is **not** a routing bug — it is a known limitation of the env-block injection, and is why Ship no longer emits self-attestation banners.

---

## Pattern classification (skill-patterns-convention.md)

`model-routing.md` is a **bundle pattern** (> 30 lines). Reference in SKILL.md via:

```
For model routing rules, read the file at ./ship/patterns/model-routing.md completely.
```
