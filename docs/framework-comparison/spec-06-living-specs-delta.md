# SPEC-06 — `ship/specs/` vivo com specs em delta

**Eixo:** memória de longo prazo + paralelismo
**Fonte da ideia:** OpenSpec (deltas ADDED/MODIFIED/REMOVED + merge mecânico no archive).

## Contexto

No modo Local, `ship/changes/<feature>/` guarda proposal/design/tasks, mas não há **fonte de
verdade viva** do comportamento acumulado do sistema. Depois de 20 features arquivadas,
"o que o sistema faz?" exige arqueologia. O `ship:analyze` só detecta drift contra a task
atual, nunca contra o comportamento total.

## O que fazer

Introduzir `ship/specs/` como verdade viva (comportamento observável, organizado por domínio).
Cada feature propõe apenas **deltas** sob headers `## ADDED / MODIFIED / REMOVED Requirements`.
No `ship:pr` (após homologação), fazer o **merge mecânico** do delta na verdade — sem LLM
reescrevendo nada, apenas aplicando ADDED (append), MODIFIED (replace) e REMOVED (delete).

## Critérios de aceite

- `ship/specs/` reflete o comportamento acumulado após cada PR.
- Merge de delta é determinístico (script, não LLM).
- `ship:analyze` pode detectar drift contra a spec total, não só a task.
- N features em paralelo sem conflito de spec (deltas isolados).

## Notas

Maior mudança conceitual, mas de maior valor composto. Gramática estrita de requirement
(`### Requirement:` + SHALL + `#### Scenario:` GWT) habilita validação por script. Melhor feita
depois que o harness da [SPEC-05](spec-05-pressure-testing.md) existe para proteger contra
regressão.
