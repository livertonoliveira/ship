# SPEC-18 — Sweep de higiene condicional + secrets no hook

**Eixo:** velocidade + segurança
**Fonte da ideia:** auditoria interna.

## Contexto

O sweep `hygiene-scan.sh --all` roda a cada fase (~600ms) mesmo quando o hook PostToolUse já não
acusou nada. Além disso, o hook detecta spec IDs e comentários, mas não secrets.

## O que fazer

1. Tornar o sweep condicional: pular se o hook não acusou violação na fase.
2. Estender o hook para flagar secrets hardcoded (API keys, tokens).

## Critérios de aceite

- Sweep pulado em fases limpas (economia de ~600ms/pipeline).
- Hook bloqueia commit com secret hardcoded.
