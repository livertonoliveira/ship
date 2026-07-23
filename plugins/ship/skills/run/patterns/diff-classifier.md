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

> **`src/hooks/quality-scope.sh` is the canonical implementation of this mapping.** Given the class and the effective enabled quality phases, it prints `run=` (phases to dispatch), `skip=`, and `log=`, and — with `--scratch` — writes the PASS skip rows for skipped phases (via `findings-gate.sh`, zero counts → PASS). `ship:run` invokes it directly rather than reasoning about the mapping in prose. The table below is documentation only.

| Class | Runs | Skipped (PASS row) | Log message |
|-------|------|--------------------|-------------|
| `trivial` | — | `perf`, `security`, `review` | `Diff trivial — fases de qualidade puladas` |
| `minor` | `security` | `perf`, `review` | `Diff minor — perf/review pulados, security mantido` |
| `normal` | all enabled | — | `Diff normal — fases de qualidade completas` |
| `large` | all enabled | — | `Diff large — fases de qualidade completas` |

Skip rows carry the note `diff <class> — pulado`:

```
| perf     | #<RUN> | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff trivial — pulado |
| review   | #<RUN> | <iso-timestamp> | - | pass | 0 | 0 | 0 | 0 | diff minor — pulado |
```

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
