# SKILL.md Pattern Reference Convention

> Validated: 2026-05-03 — MOB-1162

---

## Context

Files in `ship/patterns/` contain canonical reusable logic for all Ship skills.
The `@ship/patterns/<name>.md` notation present in existing SKILLs is **not auto-injection** —
the `@path` mechanism does not work in SKILL.md (confirmed). This notation serves as intent
documentation, not content inclusion.

Two valid strategies exist for making pattern content available to Claude during skill execution:

---

## Validated mechanisms

### Mechanism A — Inline (copy directly into SKILL.md)

Copy the pattern content directly into the SKILL.md body.

**When to use:** short patterns (≤ 30 lines), high-frequency — where the extra read cost at runtime
is not justified and the content rarely changes.

**How it works:** content becomes part of the skill prompt. Always available, no file read needed.

**Downside:** duplication — any update to the original pattern must be manually replicated in every
SKILL that inlined it.

### Mechanism B — Explicit read instruction (bundle via skill text)

Add a read instruction in the SKILL.md body:

```
Before evaluating gates, read the file at ./ship/patterns/gates.md completely.
```

**When to use:** long patterns (> 30 lines) or patterns that change frequently.

**How it works:** this is an instruction to the model — not a template expansion. Claude executes a
`Read` call during skill execution. The file is read at runtime from the project working directory.

**Evidence:** Mechanism B is an imperative instruction to the model, identical to any other prose
instruction in a SKILL.md. Claude Code executes file-read instructions as a normal part of skill
execution. No SDK expansion mechanism required.

**Correct path:** use a path relative to the project root — e.g., `./ship/patterns/gates.md`.
Do not use `${CLAUDE_SKILL_DIR}` (undocumented variable, unconfirmed in the SDK).

### Mechanism C — `${CLAUDE_SKILL_DIR}` (UNCONFIRMED)

The `${CLAUDE_SKILL_DIR}` variable **does not appear anywhere in this repository** and has no
documentation in the Claude Code SDK confirming its expansion in SKILL.md. Mark as **unconfirmed** —
do not use in production until officially validated.

### Mechanism D — Shell injection `! cat ...` in frontmatter (DISCARDED)

The `!` prefix in SKILL.md frontmatter is not a supported shell injection mechanism in Claude Code.
Completely discarded.

---

## Pattern classification

### Inline (≤ 30 lines — copy directly into SKILL.md)

| Pattern | Lines | Rationale |
|---------|-------|-----------|
| `language.md` | 5 | Very short, used in virtually all skills |
| `parallelism.md` | 6 | Very short, fundamental rule |
| `storage-mode.md` | 5 | Very short, precondition for almost all skills |
| `load-artifacts.md` | 15 | Short, context table used across the full pipeline |

### Bundle via read instruction (> 30 lines — reference in skill text)

| Pattern | Lines | Canonical read instruction |
|---------|-------|---------------------------|
| `gates.md` | 120 | `Before evaluating gates, read the file at ./ship/patterns/gates.md completely.` |
| `severity.md` | 126 | `For severity definitions, read the file at ./ship/patterns/severity.md completely.` |
| `profiles.md` | 58 | `For pipeline profile rules, read the file at ./ship/patterns/profiles.md completely.` |
| `lazy-load-findings.md` | 40 | `Before consolidating findings, read the file at ./ship/patterns/lazy-load-findings.md completely.` |
| `run-context.md` | 117 | `For the shared run context schema, read the file at ./ship/patterns/run-context.md completely.` |
| `stack-detection.md` | 48 | `To detect the project stack, read the file at ./ship/patterns/stack-detection.md completely.` |
| `security-categories.md` | 52 | `For security categories, read the file at ./ship/patterns/security-categories.md completely.` |

---

## Canonical frontmatter template for Ship SKILLs

```markdown
---
name: ship:<command-name>
description: "<command description>"
# argument-hint: omit if the skill takes no positional argument
argument-hint: "<optional argument>"
allowed-tools: Read, Glob, Grep, Bash, Agent, mcp__linear-server__*
# user-invocable: true  → skill appears in the /ship:* menu
# user-invocable: false → internal skill, invoked only by other skills
user-invocable: true
---

# Ship <CommandName> — <Title>

<!-- INLINE PATTERNS (short, ≤ 30 lines) -->
<!-- Paste the full content of applicable patterns: language.md, parallelism.md, storage-mode.md, load-artifacts.md -->
<!-- Keep the pattern section header for traceability, e.g., "## Artifact Language" -->

<!-- BUNDLE PATTERNS (long, > 30 lines) -->
<!-- For each long pattern this skill uses, add an explicit read instruction in the text -->
<!-- E.g., "Before evaluating gates, read the file at ./ship/patterns/gates.md completely." -->

[skill content here]
```

---

## Usage examples

### Inline pattern — language.md

```markdown
## Artifact Language

- All user-facing text (reports, summaries, gate results, questions) follows the `Artifact language` field in `ship/config.md → Conventions`
- Code, variable names, file paths, commits, and technical identifiers are always in English
- LLM system prompts (command files) are always in English — not configurable
```

### Inline pattern — storage-mode.md

```markdown
## Storage Mode

Read `ship/config.md` and check the `Linear Integration` section:
- If `Configured: yes` → **Linear mode** (artifacts live in Linear)
- If `Configured: no` → **Local mode** (artifacts live in `ship/changes/`)
```

### Bundle pattern — gates.md

```markdown
## Gate Evaluation

Before evaluating any gate, read the file at `./ship/patterns/gates.md` completely.
Apply the rules defined there to determine the gate result for this phase.
```

### Bundle pattern — severity.md

```markdown
## Severity Classification

For severity definitions by category (performance, security, code review, frontend, database, drift),
read the file at `./ship/patterns/severity.md` completely before classifying any finding.
```

### Bundle pattern — lazy-load-findings.md

```markdown
## Findings Consolidation

Before consolidating findings for the homologation report,
read the file at `./ship/patterns/lazy-load-findings.md` completely and apply the described algorithm.
```

### Bundle pattern — run-context.md

```markdown
## Run Context

For the full shared-context schema between agents (scratch dir, canonical files, lifecycle),
read the file at `./ship/patterns/run-context.md` completely before creating or reading files in `.context/ship-run/`.
```

### Bundle pattern — profiles.md

```markdown
## Pipeline Profiles

For pipeline profile rules (lite, standard, strict) and the default phases for each profile,
read the file at `./ship/patterns/profiles.md` completely before building the effective phase set.
```

### Bundle pattern — stack-detection.md

```markdown
## Stack Detection

To detect the project stack from `ship/config.md` or repository signal files,
read the file at `./ship/patterns/stack-detection.md` completely.
```

### Bundle pattern — security-categories.md

```markdown
## Security Categories

For attack categories and security analysis scope,
read the file at `./ship/patterns/security-categories.md` completely before starting the scan.
```

---

## Inline pattern maintenance

When the content of an inline pattern (`language.md`, `parallelism.md`, `storage-mode.md`,
`load-artifacts.md`) is updated, the change must be manually replicated in every SKILL that
inlined it.

**Procedure:**
1. Find all SKILLs containing the pattern section header
   (e.g., `grep -r "## Artifact Language" plugins/ship/`)
2. Apply the update in each file found
3. CI validates that SKILLs do not reference the harness binary — there is no automatic
   sync validation for inline patterns; the developer editing the original pattern is responsible

**Tip:** when creating a new SKILL, inline only the patterns it actually uses — avoid copying all
patterns by default.

---

## Test results — MOB-1162

| Mechanism | Status | Evidence |
|-----------|--------|----------|
| **Inline** (copy into SKILL.md) | CONFIRMED | Content is part of the prompt — no runtime dependency |
| **Explicit read instruction** (Mechanism B) | CONFIRMED | Imperative instruction to the model; Claude executes `Read` normally during skills |
| `${CLAUDE_SKILL_DIR}` | UNCONFIRMED | No occurrences in the repository; no SDK documentation |
| Shell injection `! cat ...` | DISCARDED | Not supported by Claude Code |
| `@path` in SKILL.md | DISCARDED | Confirmed non-functional in SKILL.md |

**Mechanism B validation:** the test file at `ship/tmp/test-skill-patterns.md` contains an
explicit read instruction (`read the file at ./ship/patterns/gates.md`). When this skill executes,
Claude receives the instruction and issues a `Read` call for the file — identical behavior to any
other file-read instruction in prose within a SKILL.md.

---

## Final decision

**Convention adopted for Ship SKILLs:**

1. **Short patterns (≤ 30 lines):** include inline, with a section header identifying the source
2. **Long patterns (> 30 lines):** reference via explicit read instruction in the skill text
3. **`${CLAUDE_SKILL_DIR}`:** do not use until officially confirmed in the SDK
4. **`@path` in SKILL.md:** never use — does not work
