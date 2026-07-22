#!/usr/bin/env bash
# Ship destructive-git guard — PreToolUse hook on Bash.
#
# Reads a PreToolUse JSON event on stdin, extracts the command about to run, and blocks it
# (exit 2, message on stderr) if it matches a git command that discards uncommitted or
# untracked work without any possibility of recovery: `git clean -f`, `git checkout -- .` /
# `git checkout .`, `git reset --hard`, `git branch -D`, `git push --force`.
#
# This exists because an uncommitted, never-recovered file was permanently lost by exactly
# this sequence (`git clean -fd` + `git checkout -- .`) run mid-debugging without confirmation.
# The fix is a deterministic tripwire, not a reminder to "be careful" — the model asks the
# user to confirm (or runs a safe alternative like `git stash -u`) instead of proceeding.
#
# Exit 0 = allowed. Exit 2 = blocked, reason printed to stderr for the model to relay.

set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*[,}].*/\1/p' | head -1)"

[ -n "$command" ] || exit 0

is_destructive() {
  local c="$1"

  if printf '%s' "$c" | grep -qE 'git[[:space:]]+clean\b'; then
    if ! printf '%s' "$c" | grep -qE -- '(^|[[:space:]])-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)|--dry-run\b'; then
      if printf '%s' "$c" | grep -qE -- '-[a-zA-Z]*f[a-zA-Z]*\b|--force\b'; then
        return 0
      fi
    fi
  fi

  printf '%s' "$c" | grep -qE 'git[[:space:]]+checkout[[:space:]]+--[[:space:]]+\S' && return 0
  printf '%s' "$c" | grep -qE 'git[[:space:]]+checkout[[:space:]]+\.([[:space:]]|$)' && return 0
  printf '%s' "$c" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard\b' && return 0
  printf '%s' "$c" | grep -qE 'git[[:space:]]+branch[[:space:]]+-D\b|git[[:space:]]+branch\b.*--delete.*--force' && return 0
  printf '%s' "$c" | grep -qE 'git[[:space:]]+push\b.*--force\b' && return 0

  return 1
}

if is_destructive "$command"; then
  {
    echo "Ship guard: blocked a destructive git command that would discard uncommitted or untracked work irrecoverably:"
    echo
    echo "  $command"
    echo
    echo "Before running anything like this, show the user what 'git status' / 'git diff' report would be lost and get their explicit confirmation. Prefer a reversible alternative first (e.g. 'git stash -u', or committing work-in-progress) over an irreversible discard."
  } >&2
  exit 2
fi

exit 0
