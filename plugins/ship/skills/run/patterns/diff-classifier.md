# Diff Classifier — Deterministic Heuristic

Classifies the diff in `.context/ship-run/<task-id>/diff.md` into one of four classes
and adjusts which quality agents run in Phase 4 of `/ship:run`.

> **No LLM calls.** All classification is computed via bash-parseable rules only.

> `src/hooks/diff-classify.sh` is the canonical implementation of the metrics, sensitive-path
> parsing, top-down rules, and output format described below. The bash snippets in this document
> are reference/documentation only — they transcribe the same logic for readability, but
> `ship:run` invokes the script directly rather than executing these snippets.

---

## Classification Criteria

### Line count

Count changed lines (add `+` and remove `-` lines, excluding `+++`/`---` headers):

```bash
grep -E '^[+-]' diff.md | grep -Ev '^(\+\+\+|---)' | wc -l
```

### Logical file count

Count unique modified source files, excluding documentation/config-only extensions:

```bash
grep '^+++ b/' diff.md | sed 's|^+++ b/||' \
  | grep -Ev '\.(md|json|lock|txt|ya?ml)$' | sort -u | wc -l
```

### New endpoint detection

Check for new route/endpoint patterns added by the diff:

```bash
grep '^+' diff.md | grep -Ev '^\+\+\+' \
  | grep -E "route\(|app\.(get|post|put|patch|delete)\(|@(Get|Post|Put|Patch|Delete)\(" \
  | wc -l
```

### Sensitive path detection

Check if any added file in the diff touches a sensitive path:

```bash
grep '^+++ b/' diff.md | sed 's|^+++ b/||' \
  | grep -E '^(auth/|payment/|query|migrations/)' | wc -l
```

Default sensitive prefixes: `auth/`, `payment/`, `query`, `migrations/`.
Override by adding `## Sensitive Paths` to `ship/config.md` (see format below).

---

## Classification Rules (evaluated top-down, first match wins)

| Class | Conditions |
|-------|-----------|
| `trivial` | ALL of: (a) only files with ext `*.md`, `*.json`, `*.lock`, `*.txt`, `*.yml`, `*.yaml` modified; (b) zero sensitive path matches; (c) total diff < 50 lines |
| `large` | total diff > 1000 lines OR logical files > 10 |
| `minor` | total diff < 100 lines AND logical files ≤ 1 AND zero new endpoint patterns |
| `normal` | everything else (default) |

> `large` is checked before `minor` so a 1200-line single-file change is `large`, not `minor`.

---

## Sensitive Paths Override (in `ship/config.md`)

When the `## Sensitive Paths` section is present, its entries **replace** (not extend) the defaults:

```markdown
## Sensitive Paths
# Optional — paths that force 'normal' classification even for trivial diffs.
# Format: one path prefix per line (relative to repo root).
# Defaults if section is absent: auth/, payment/, query, migrations/
# - auth/
# - payment/
# - migrations/
```

Parse the section: extract non-comment lines starting with `- ` and strip the leading `- `.

---

## Behavior per Class

`analyze` participates in the same Phase 4 fan-out as `perf`/`security`/`review` (see `run/SKILL.md` → Phase 4), so its per-class behavior is decided here alongside theirs:

| Class | Quality agents | `analyze` | Log message |
|-------|---------------|-----------|-------------|
| `trivial` | Skip all (`perf`, `security`, `review`) — mark all as gate=PASS | Skipped — mark gate=PASS, same as the other three | `Diff trivial — fases de qualidade puladas` |
| `minor` | Run 1 combined security agent only; skip `perf` and `review` | **Runs** — drift detection is independent of diff size | `Diff minor — security combinado, perf/review pulados, analyze mantido` |
| `normal` | Current behavior — up to 3 parallel agents | Runs | `Diff normal — fases de qualidade completas` |
| `large` | Current behavior — up to 3 parallel agents | Runs | `Diff large — fases de qualidade completas` |

`trivial` is the only class where `analyze` is skipped: a diff that touches only doc/config files with zero sensitive-path matches has nothing for drift correlation to check either. Every other class runs `analyze` regardless of how `perf`/`security`/`review` are adjusted, because spec↔code drift can appear in a single-file, sub-100-line change just as easily as in a large one.

### `trivial` — phase-status.md entries

Append one PASS row for each skipped quality phase (`analyze` included):

```
| perf     | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
| security | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
| review   | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
| analyze  | #1 | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
```

### `minor` — combined security agent

Launch a single security agent instructed to cover all three OWASP categories
(Injection + Auth + Data/Config) in one pass. Write findings to the same
`security-findings-<task-id>.md` file as normal mode. `perf` and `review` rows
in `phase-status.md` are written as gate=PASS with notes `diff minor — pulado`.
`analyze` dispatches normally (same as `normal`/`large`) and its row in
`phase-status.md` carries its own gate result — it is never marked `pulado` in
`minor` class.

---

## Output

Write the classification result to:

```
.context/ship-run/<task-id>/diff-class.txt
```

Content: a single word — `trivial`, `minor`, `normal`, or `large`.

---

## Compute & Log

After writing `diff-class.txt`, log to the user:

```
Diff class: <class> (<reason>)
```

Where `<reason>` is a short human-readable explanation, e.g.:
- `trivial` → `only doc/config files, 12 lines, no sensitive paths`
- `minor` → `48 lines, 1 logical file, no new endpoints`
- `normal` → `default classification`
- `large` → `1 240 lines changed`
