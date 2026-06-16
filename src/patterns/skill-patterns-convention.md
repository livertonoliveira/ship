# SKILL/Agent Pattern Reference Convention

> Rewritten 2026-06-15 — supersedes the MOB-1162 notes, which predated the build-time
> resolver and the documented `${CLAUDE_SKILL_DIR}` mechanism and were misleading.

Patterns in `src/patterns/` (plus `src/report-templates.md`, `src/linear-audit-template.md`)
hold canonical reusable logic for Ship skills and agents. There are **three** ways their
content reaches the model. Pick per pattern by size and how often the branch that needs it runs.

---

## Mechanism A — Build-time inline (`@ship/<path>.md`)

`build.js` replaces `@ship/<path>.md` (and `@ship/<path>.md#anchor` for a section) with the
file's content when generating `plugins/ship/`. The reference disappears; the content is part of
the shipped skill/agent and loads whenever it is invoked.

- **Use for:** content needed on essentially every run, and **the only option for named agents**
  (`agents/*.md`) — agents have no `${CLAUDE_SKILL_DIR}`.
- **Dedup:** each unique `(path, anchor)` is inlined **once per output file**; later references to
  the same pattern become a short pointer ("the … section (included above)"). So repeating a
  reference for cross-linking is free — do not hand-inline.
- **Cost:** every inlined line is in the prompt for the whole session.

## Mechanism B — Lazy bundle (`@@ship/<path>.md`) — skills only

`build.js` does **not** inline a `@@` reference. It copies the file next to the skill
(`plugins/ship/skills/<name>/<path>`) and replaces the token with `${CLAUDE_SKILL_DIR}/<path>`,
a render-time substitution that resolves to an absolute path. The model reads the file **on
demand** with the Read tool, so the body stays out of the always-loaded prompt.

- **Use for:** large and/or **conditional** patterns — content only some runs need (e.g. a
  Linear-only recipe, a fix-only re-run procedure). Write an explicit imperative around it:
  `` read `@@ship/patterns/gates.md` completely before applying this procedure. ``
- **Constraints:** skills only (agents are rejected at build); **whole-file only** (no `#anchor` —
  reading a whole file to get one section defeats the purpose; split the source file first).
- **Do not** lazy-load content that is critical AND needed on the happy path — the small token
  win is not worth a missed on-demand read. Inline it (Mechanism A) instead.
- **Validation:** `${CLAUDE_SKILL_DIR}` substitution + on-demand Read confirmed in a forked skill
  (the Read tool received the substituted absolute path; Read cannot expand shell variables).

## Mechanism C — Runtime command variable (`${CLAUDE_PLUGIN_ROOT}`)

`${CLAUDE_PLUGIN_ROOT}` is injected by the harness **only into executed commands** — hook
commands, MCP/LSP server configs, monitor commands (e.g. `bash "${CLAUDE_PLUGIN_ROOT}/hooks/…"`).
It is **not** available in skill/agent prose or in subagent Bash tool calls (verified UNSET).
Never rely on it to read pattern files from a skill or agent body.

---

## Quick rules

1. Agent file → only Mechanism A.
2. Skill, content needed almost always → Mechanism A.
3. Skill, content large and conditional → Mechanism B (`@@`) with an explicit read instruction.
4. Referencing a pattern more than once in a file → fine; build dedups (A) or repeats a cheap path (B).
5. Never write the literal `${CLAUDE_PLUGIN_ROOT}` in a skill/agent body expecting it to resolve.

## Build

After editing anything under `src/`, run `cd plugins/ship && npm run build` and commit the result —
CI fails on drift between `src/` and `plugins/ship/skills|agents/` (the latter now includes bundled
lazy `patterns/` dirs).
