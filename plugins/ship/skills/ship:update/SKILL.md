---
name: ship:update
description: "Updates all Ship command files to the latest version."
argument-hint: ""
allowed-tools: Read, Write, Bash
user-invocable: true
---

# Ship Update

## Step 1 — Detect install mode and update command files

First, check which install mode is active by running:

```bash
test -d ".claude/commands/ship" && echo "LOCAL" || echo "PLUGIN"
```

### If LOCAL (`.claude/commands/ship/` exists in the current project)

Run the update script:

```bash
curl -sL https://raw.githubusercontent.com/livertonoliveira/ship/main/update.sh | bash
```

The script will:
- Overwrite all command files unconditionally
- Report which files were updated and which failed
- Update itself (`update.md`) as part of the run

No diff checks, no prompts.

### If PLUGIN (installed globally via `claude plugin install`)

The update script cannot update global plugin files. Instruct the user to run the following command in their terminal and restart Claude Code:

```bash
claude plugin update ship@ship-marketplace
```

This will pull the latest version from the `livertonoliveira/ship` GitHub repository and replace all skill files in the global plugin cache. A Claude Code restart is required for the changes to take effect.

After the user confirms the update is done (or you detect the mode was PLUGIN), proceed to Step 2.

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

**"Ship is not installed in this project"** — You're using a local install (`.claude/commands/ship/`) but it doesn't exist. Run the installer:

```bash
curl -sL https://raw.githubusercontent.com/livertonoliveira/ship/main/install.sh | bash
```

**Using the global plugin install** — Use `claude plugin update ship@ship-marketplace` in the terminal instead of the update script. See Step 1 above.
