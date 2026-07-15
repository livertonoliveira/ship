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

Consumed via `@ship/patterns/vague-terms.md` (Mechanism A — build-time inline; agents only
support inline, per `src/patterns/skill-patterns-convention.md`) by the AMBIG pre-filter.
