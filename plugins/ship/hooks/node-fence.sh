#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# node-fence.sh — PreToolUse (Edit|Write): inside a work-graph node's workspace,
# no agent edits a file outside it.
#
# Measured 2026-10-07: three frontend nodes were given backend checkouts, their
# develop found none of the files it was asked to change, and went to edit them
# where they did exist — one in the user's own clone of the frontend, on a
# branch it switched that clone to. A node's workspace is the only tree its
# pipeline commits, PRs and seals; an edit anywhere else is lost to the run and
# lands on someone else's work.
#
# Only a node workspace is fenced (a run there records graph-node.txt), so a
# person's own session is never affected. Temp dirs and Claude's own config
# stay writable. Every unexpected input exits 0: a hook must never break a run.
# ---------------------------------------------------------------------------

input="$(cat)"
path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
root="${CLAUDE_PROJECT_DIR:-}"
[ -n "$path" ] && [ -n "$root" ] || exit 0
ls "$root"/.context/ship-run/*/graph-node.txt >/dev/null 2>&1 || exit 0

case "$path" in
  /*) ;;
  *) exit 0 ;;
esac
case "$path" in
  "$root"/*|/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"$HOME"/.claude/*) exit 0 ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ship: %s is outside this graph node'"'"'s workspace (%s). A node changes only its own checkout. If the files the task names are not here, the node was given the wrong repo: report that and stop — never edit another checkout."}}\n' "$path" "$root"
exit 0
