---
name: ship:update
description: "Updates all Ship command files to the latest version."
argument-hint: ""
allowed-tools: Read, Write, Bash
user-invocable: true
---

# Ship Update

## Step 1 — Update command files

Run the following command in the terminal:

```bash
curl -sL https://raw.githubusercontent.com/livertonoliveira/ship/main/update.sh | bash
```

The script will:
- Overwrite all command files unconditionally
- Report which files were updated and which failed
- Update itself (`update.md`) as part of the run

No diff checks, no prompts.

---

## Step 2 — Migrate ship/config.md

After the command files are updated, check if `ship/config.md` exists in the current project.

- If it does **not** exist: skip migration (project not initialized — user should run `/ship:init`).
- If it **exists**: run the config migration below.

### Config migration

Read `ship/config.md` and check for each required section listed in the **Migration Registry** below. For each section that is **missing**, inject it into the file at the correct position (see registry). Do NOT overwrite any existing content.

After injecting all missing sections, report a summary to the user in the artifact language from `ship/config.md → Conventions → Artifact language` (default to English if absent):

```
Config migration complete:
- Added: ## Test Scope
- Already present: (all other sections)
```

If nothing was missing, report: `Config already up to date — no migration needed.`

---

## Migration Registry

Each entry defines a section that must exist in `ship/config.md`, how to detect it, how to generate the default value, and where to inject it if missing.

### `## Test Scope`

**Detect:** search for a line that starts with `## Test Scope` in `ship/config.md`.

**Default (by project type):**

Read `## Project Type` from `ship/config.md` to determine the project type.

| Project type | unit | integration | e2e |
|---|---|---|---|
| `prompt-toolkit` | enabled | disabled | disabled |
| `library` | enabled | disabled | disabled |
| `frontend` | enabled | disabled | disabled |
| `mobile` | enabled | disabled | disabled |
| `backend` | enabled | enabled | disabled |
| `fullstack` | enabled | enabled | disabled |
| `monorepo` | enabled | enabled | disabled |
| *(unknown / not detected)* | enabled | disabled | disabled |

**Inject after:** `## Pipeline Phases` block (the block that contains `- pr: enabled`). If `## Pipeline Phases` is not present, inject before `## Conventions`.

**Content to inject:**

```markdown
## Test Scope
# Which test layers /ship:test generates per task.
# Layers disabled here are NOT generated during the pipeline,
# but can be backfilled via /ship:audit:tests.
- unit: [enabled|disabled]
- integration: [enabled|disabled]
- e2e: disabled
```

Replace `[enabled|disabled]` with the values from the table above for the detected project type.

---

## Troubleshooting

If the script reports `Ship is not installed in this project`, run the installer instead:

```bash
curl -sL https://raw.githubusercontent.com/livertonoliveira/ship/main/install.sh | bash
```
