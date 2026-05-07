# Ship Config

## Project
- Name: Ship Lite
- Type: prompt-toolkit

## Linear Integration
- Configured: yes
- Team: Mobitech
- Team ID: 90497937-52ef-4562-9273-ade6c868032a

## Gate Behavior
- on_fail: fix
- on_warn: fix
- on_fail_rerun: surgical   # surgical (default) | all

## Severity Overrides
# Optional section. Remove entirely if not needed.
# Format: - <phase>: <from-severity>→<to-severity>
# Valid phases: dev, test, perf, security, review, frontend-perf, database, backend
# Valid transitions: critical→high, critical→warn, high→warn, medium→low
# Example:
# - perf: high→warn          # downgrade high perf findings to warn
# - frontend-perf: high→warn # same for frontend-perf phase
# - security: medium→low     # downgrade medium security to low

## Security Focus
# Optional section. Remove entirely to default to 'all'.
# Valid values: all | web-api | mobile | infrastructure | none
- categories: all

## Pipeline Profile
- profile: standard   # lite | standard | strict
                      # explicit entries in Pipeline Phases below override the profile

## Pipeline Phases
- dev: enabled
- test: enabled
- perf: enabled
- security: enabled
- review: enabled
- homolog: enabled
- pr: enabled

## Test Scope
# Which test layers /ship:test generates per task.
# Layers disabled here are NOT generated during the pipeline,
# but can be backfilled via /ship:audit:tests.
- unit: enabled
- integration: disabled
- e2e: disabled

## Conventions
- Artifact language: pt-BR (specs, issues, docs, milestones, reports, PR descriptions, Linear comments)
- Prompt language: en (LLM system prompts — hardcoded, not configurable)
- Code language: English (code, variable names, commits, branch names)
- Commit style: Conventional Commits (feat:, fix:, refactor:, test:, chore:)
- Branch naming: <type>/<issue-id>-<short-description>
- Atomic commits: one logical change per commit
- Co-author: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
