# Hygiene Gate — deterministic enforcement for comments & spec IDs

> Canonical enforcement of the zero-comments / zero-spec-IDs rule. The worker prompts forbid
> comments and spec IDs, but a prompt is advice, not a guarantee — an LLM occasionally emits
> them anyway.
>
> **Three layers, distinct roles — do not collapse them:**
>
> 0. **Prevention by construction (the real fix): de-identify the worker context.** The
>    orchestrators strip spec IDs from the scenario/contract text before injecting it into a worker
>    — what the worker never receives, it cannot echo. See `@ship/patterns/deidentify-context.md`.
>    This removes the dominant leak path (inline pipeline generation) at the source. The two layers
>    below are the net for what prevention cannot reach (standalone workers, a Linear key picked up
>    from the branch, and comments — which have no input to strip).
> 1. **Detection (genuinely deterministic): the `PostToolUse` hook.** The plugin ships
>    `hooks/hygiene-scan.sh`, wired as a `PostToolUse` hook on `Write|Edit`. It fires the moment
>    a file is written, scans *that* file, and on a hit **exits 2** so Claude Code blocks the
>    turn and feeds the `file:line` violations back to the model — which then renames the
>    identifier / removes the comment inline (the semantic fix a script cannot do safely). This
>    layer does **not** depend on any agent choosing to run it; it is the actual guarantee that
>    nothing passes. It catches violations per-file, at the source, while the model still holds
>    full context.
> 2. **Final sweep (belt-and-suspenders): the SKILL step below.** Runs the same grep over the
>    whole working tree at phase end and dispatches a `Mode: clean` worker for anything left.
>    With the hook in place this should normally find nothing; it is a redundant safety net, **not**
>    the primary defense. Never treat this step as the thing standing between you and a leak — the
>    hook is.
>
> The grep is a **tripwire, not a judge**: it flags candidate files cheaply; the model (hook) or
> the dispatched cleanup worker (sweep) decides what is a genuine comment / spec ID and strips
> only those, leaving legitimate tokens (e.g. `UTF-8`, `SHA-256` in a string) untouched.
>
> **Scope of the hook (two rules, two reaches):**
> - **Spec IDs** (`REQ-/AC-/SC-/IMPL-/TEST-<n>` + the branch's Linear key) are flagged on **every**
>   `Write`/`Edit` — they are always wrong in code, and the precise regex never false-positives on
>   `UTF-8`/`SHA-256`/etc.
> - **Comments** are a Ship convention, not a universal rule, so they are flagged **only inside an
>   active Ship run** (a `.context/ship-run/` marker dir at the repo root) and **only on lines added
>   relative to `HEAD`** (untracked files count as fully added). Pre-existing comments in a file a
>   worker merely edited are never flagged — stripping them broke typecheck and burned fix→re-review
>   cycles. Outside a run, the hook does not police the user's hand-written comments. The whole-tree
>   `--all` sweep enables both rules, with the same added-lines scope for comments.
>
> **Caveat:** the hook only catches `Write`/`Edit` going forward and only where the Ship plugin
> is enabled. Spec IDs already committed in earlier runs are not swept retroactively — run
> `bash "${CLAUDE_PLUGIN_ROOT}/hooks/hygiene-scan.sh" --all` once to list them for manual cleanup.

## What counts as a violation

In **source and test files only** (artifacts are exempt — see exclusions):

1. **Spec IDs** — `REQ-<n>`, `AC-<n>`, `SC-<n>`, `IMPL-<...>`, `TEST-<...>`, or the current task's
   **Linear issue key** (the team prefix + number, e.g. `MOB-1734`, `ENG-42`) appearing **anywhere**:
   identifiers, test/describe names, string literals, or comments.
2. **Comments of any kind** — line comments, block comments, JSDoc/TSDoc, docstrings, marker
   comments. Naming carries the meaning; there are no exceptions for "why" comments.

## Exclusions (these are NOT scanned)

Spec IDs are **legitimate** in artifacts and reports. Never scan:
- `ship/**` (proposal/design/tasks/reports in local mode)
- `**/*.md` (any markdown — specs, reports, docs)
- `.context/**` (scratch dir, gitignored)
- lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `go.sum`, `Cargo.lock`, `*.lock`

Everything else changed in the working tree is treated as code/test and **is** scanned.

## Step 1 — Collect the candidate set (working-tree state)

The pipeline does not commit until `ship:pr`, so violations live in the **uncommitted** working
tree — both tracked edits and brand-new untracked files. Collect both, applying the exclusions:

```bash
EXCLUDES=':(exclude)ship/**' ':(exclude)*.md' ':(exclude).context/**' \
         ':(exclude)package-lock.json' ':(exclude)pnpm-lock.yaml' ':(exclude)yarn.lock' \
         ':(exclude)go.sum' ':(exclude)Cargo.lock' ':(exclude)*.lock'

# Tracked edits since HEAD (added lines only)
git diff HEAD --unified=0 -- . "${EXCLUDES[@]}" > /tmp/ship-hygiene-diff.txt

# New untracked files (whole file is "added")
git ls-files --others --exclude-standard -- . "${EXCLUDES[@]}" > /tmp/ship-hygiene-untracked.txt
```

If both are empty, the gate **passes** with nothing to do.

## Step 2 — Derive the Linear key pattern

If a task-id of the form `<PREFIX>-<n>` was passed (Linear mode), capture `<PREFIX>` and add
`\b<PREFIX>-[0-9]+\b` to the spec-ID regex. In local mode (task-id is a slug), skip this — only
the fixed Ship prefixes apply.

## Step 3 — Scan for spec IDs (precise — every hit is a real violation)

Restricted to Ship's own prefixes plus the derived Linear key, so it will **not** false-positive on
`UTF-8`, `SHA-256`, `ISO-8601`, `RFC-7231`, etc.:

```bash
SPEC_RE='\b(REQ|AC|SC|IMPL|TEST)-[0-9]+\b'          # + |\bMOB-[0-9]+\b style key from Step 2

# tracked added lines
grep -E '^\+' /tmp/ship-hygiene-diff.txt | grep -vE '^\+\+\+' | grep -nE "$SPEC_RE"
# untracked files
while IFS= read -r f; do [ -n "$f" ] && grep -nE "$SPEC_RE" "$f" | sed "s|^|$f:|"; done < /tmp/ship-hygiene-untracked.txt
```

## Step 4 — Scan for comments (tripwire, scoped by extension)

Match the comment syntax of the file's language. A hit inside a string literal (a URL with `//`)
is a possible false positive — that is fine, it only **triggers** a cleanup pass; the worker leaves
real code alone. Conservative per-extension markers:

| Extensions | Comment markers to flag (on added lines / in untracked files) |
|------------|----------------------------------------------------------------|
| `.ts .tsx .js .jsx .go .java .kt .swift .c .cpp .cs .rs .scala .php` | `//`, `/*`, `*/`, leading ` * ` (JSDoc body) |
| `.py .rb .sh .bash .zsh .yaml .yml .toml .r` | leading or trailing `#` (not `#!` shebang on line 1, not `#{` interpolation) |
| `.py` | `"""` / `'''` docstrings |
| `.sql .lua .hs` | `--` |
| `.html .vue .svelte` | `<!--`, `-->` |
| `.clj .lisp .el` | `;` |

Run the same two-source scan (tracked added lines + untracked files) with the extension's pattern.
Collect the set of **files** that hit (with line numbers) — that set feeds Step 5.

## Step 5 — Remediate (auto-fix, do not just report)

If Step 3 or Step 4 found nothing → gate **PASS**, continue the phase.

If anything was found:

1. **Dispatch a cleanup worker** via the Agent tool, `Mode: clean`, one call covering all flagged
   files. Use the **same worker type** that produced them:
   - `ship:develop` → `ship:ship-develop-implement`
   - `ship:test` → the matching `ship:ship-test-*` worker for each flagged test file
2. The cleanup prompt lists the exact `file:line` hits and instructs: remove every genuine comment;
   strip or rename every spec ID / Linear key (rename the identifier to describe the behavior — do
   not annotate); leave legitimate tokens that merely resemble a pattern (e.g. `UTF-8` in a string)
   untouched; change nothing else.
3. **Re-run Steps 1–4.** If clean → PASS. If hits remain → dispatch one more cleanup cycle.
4. **Max 2 cleanup cycles.** If violations still remain after the second cycle, do **not** silently
   pass: record the remaining `file:line` hits in the phase report and surface them to the caller as
   a `warn` so a human sees exactly what slipped through. Never report PASS while known hits remain.

## Cleanup worker prompt template

```
Mode: clean
Task: <task-id>
Artifact language: <artifact_language>

The hygiene gate found forbidden content in files you (or a sibling worker) generated.
Remove it — change NOTHING else.

## Violations (file:line)
<the exact grep hits>

## What to remove
- Every comment of any kind (line, block, JSDoc/TSDoc, docstring, marker). No exceptions.
- Every spec ID (REQ-/AC-/SC-/IMPL-/TEST-<n>) and Linear issue key (<PREFIX>-<n>), wherever it
  appears — identifiers, test/describe names, strings. Rename the identifier to describe the
  behavior; do not annotate.

## What to leave alone
- Legitimate tokens that merely resemble a pattern (UTF-8, SHA-256, ISO-8601 inside a string).
- All other code. Do not refactor, reformat, or expand scope.
```
