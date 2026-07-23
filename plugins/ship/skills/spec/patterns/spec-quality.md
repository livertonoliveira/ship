# Spec Quality Gate (AMBIG / SUBSPEC / PRINCIPLE)

Semantic quality passes over the **drafted spec text** (REQ-XX / AC-XX), run once at spec time — after the clarify marker gate, before any artifact is created. These passes audit the spec, not code, so they never run inside the development pipeline (`/ship:run`).

## Pre-filters (local, zero LLM)

Select candidates first; items that survive no pre-filter are never sent to the sub-agent.

1. **AMBIG candidates** — check each REQ-XX/AC-XX description against the vague-terms dictionary below for the active `Artifact language`. A term match selects the item as a candidate for LLM confirmation. No dictionary hit → no candidate, skip the item entirely. A term already accompanied, in the same clause, by an explicit measurable threshold (e.g., "rápido (< 200ms)", "p95 < 200ms", "≥ 99.9%") must not be selected.

# Vague Terms Dictionary

Lookup of vague/qualitative terms commonly found in requirement/AC prose that lack a
measurable threshold. Keyed by artifact language (see `ship/config.md → Artifact language`).

This dictionary is a **pre-filter**: a hit here means "candidate for LLM confirmation", not
an automatic finding. A term accompanied by an explicit measurable threshold in the same
clause (e.g. "rápido (< 200ms)", "fast (p95 < 200ms)") must not be flagged by the consumer.
Severity, schema, and reporting format are defined elsewhere (`src/patterns/severity.md`,
`src/report-templates.md`), not here.

## pt-BR

- rápido / rapidamente
- lento / lentamente
- escalável / escalabilidade
- seguro / segurança (sem controle nomeado)
- eficiente / eficiência
- robusto / robustez
- confiável / confiabilidade
- performático
- responsivo
- intuitivo
- amigável
- flexível
- simples (sem critério objetivo)
- adequado
- suficiente
- otimizado

## en

- fast / quickly
- slow / slowly
- scalable / scalability
- secure / security (no named control)
- efficient / efficiency
- robust / robustness
- reliable / reliability
- performant
- responsive
- intuitive
- friendly / user-friendly
- flexible
- simple (no objective criterion)
- adequate
- sufficient
- optimized

## Consumption

Consumed via `the vague-terms.md pattern (included above)` (build-time inline) by the AMBIG pre-filter in
`src/patterns/spec-quality.md`, which `spec/SKILL.md` lazy-loads at spec time. Not consumed
by any pipeline phase.

2. **SUBSPEC candidates** — a REQ-XX is a candidate only if it has zero linked AC-XX, or every linked AC-XX description lacks an explicit measurable condition/threshold (no comparison operator, unit, percentage, or numeric bound). A REQ-XX with at least one measurable AC is resolved locally as "not underspecified" and skipped.

3. **PRINCIPLE scope** — locate declared conventions (`## Conventions` or equivalent in the drafted proposal/design, or `ship/config.md`). No declared convention anywhere → skip the pass entirely.

## Single batched sub-agent

If at least one candidate/convention survived, dispatch **exactly one** sub-agent (Agent tool, `model: "sonnet"`) carrying ALL candidates in a single prompt — never one dispatch per item. Fixed rubrics:

- **AMBIG** (per candidate REQ/AC): "does the item contain a qualitative attribute with no measurable threshold?" — if a measurable threshold is present in the same clause, return a negative confirmation (not ambiguous).
- **SUBSPEC** (per candidate REQ): "does this requirement have a testable acceptance criterion? does each of its acceptance criteria have a verifiable pass/fail condition?" A REQ with zero linked AC-XX, or an AC whose condition is not verifiable, is a violation.
- **PRINCIPLE** (once, if conventions declared): check adherence of each REQ-XX/AC-XX to the declared conventions.

The sub-agent returns strict JSON — an array of findings, no free-form prose:

```json
{
  "category": "AMBIG | SUBSPEC | PRINCIPLE",
  "severity": "medium",
  "itemId": "REQ-XX | AC-XX",
  "description": "what is vague/missing/violated",
  "suggestion": "concrete rewrite of the item text"
}
```

Never accept prose-only responses. A negative confirmation produces no finding for that item.

## Handling findings

Findings are **spec defects — fix them in the spec text now**, while it is still a draft:

- **Interactive mode**: present each finding with its suggested rewrite and ask the user to accept, edit, or dismiss. Apply accepted rewrites to the drafted Proposal/issue content before creating any Linear/local artifact.
- **Headless mode**: do not block. Append the findings under a `## Spec Quality Notes` section of the Proposal and continue.

No candidates, or no finding confirmed → log a single line ("Spec quality: 0 achados") and proceed. These findings never gate the pipeline: once the spec is created, the development pipeline does not re-audit spec quality.
