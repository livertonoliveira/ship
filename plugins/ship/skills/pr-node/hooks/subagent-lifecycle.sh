#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# subagent-lifecycle.sh — what the pipeline used to ask its workers to do in
# prose, done by the harness instead (plugin hooks, hooks/hooks.json).
#
#   start  (SubagentStart) — writes worker-start-<name>.txt: the start epoch on
#          line 1 (report-timings reads it for the dispatch lag), the agent id on
#          line 2. Before this the prompt said "First action, before any read:
#          run Bash date" — a turn spent per worker, and a timestamp that was
#          missing whenever the worker skipped the instruction.
#   stop   (SubagentStop) — a worker the pipeline dispatched may not finish
#          without writing the files its phase is read from. Workers had claimed
#          completion with nothing on disk; the gate then failed the phase
#          after the fact, with the context that could have written them gone.
#          Blocks once (exit 2, the reason goes back to the worker); the second
#          stop is let through and the fail-closed gates take it from there.
#          A worker let through gets worker-done-<name>.txt, which is what
#          pipeline.sh next waits on for a worker launched in the background.
#   guard  (PreToolUse Edit|Write) — a test worker may not edit a path its
#          brief's ## Denylist names (the source under test).
#
# Only agents the pipeline dispatched are touched: the run is identified by a
# timings.tsv row for the worker written in the last 15 minutes, and stop/guard
# by the agent id recorded at start. A standalone /ship:review or /ship:test is
# left alone. Every unexpected input exits 0 — a hook must never break a run.
# ---------------------------------------------------------------------------

input="$(cat)"

json_field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}
json_bool() {
  printf '%s' "$input" | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*(true|false).*/\\1/p" | head -1
}

agent_type="$(json_field agent_type)"
agent_id="$(json_field agent_id)"
cwd="$(json_field cwd)"
[ -n "$cwd" ] || cwd="$PWD"
case "$agent_type" in
  ship:ship-*) name="${agent_type#ship:}" ;;
  *) exit 0 ;;
esac
# The hook's cwd is wherever the agent last cd'd to. Measured 2026-10-06: test
# workers that cd'd into a subdirectory were never found, never marked done, and
# pipeline.sh next waited on them until the graph failed the node. The run is
# found by walking up from cwd, then from the session's project dir.
find_runs() {
  local d
  for d in "$cwd" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$d" ] || continue
    while :; do
      [ -d "$d/.context/ship-run" ] && { printf '%s/.context/ship-run' "$d"; return 0; }
      [ "$d" = "/" ] || [ "$d" = "." ] && break
      d="$(dirname "$d")"
    done
  done
}
runs="$(find_runs)"
[ -n "$runs" ] || exit 0
cwd="${runs%/.context/ship-run}"

# The scratch dir whose worker-start file this agent wrote at start.
scratch_of_agent() {
  local f
  [ -n "$agent_id" ] || return 0
  for f in "$runs"/*/worker-start-"$name".txt; do
    [ -f "$f" ] || continue
    if [ "$(sed -n 2p "$f")" = "$agent_id" ]; then
      dirname "$f"
      return 0
    fi
  done
}

cmd_start() {
  local now t epoch row best="" best_epoch=0 d
  now="$(date -u +%s)"
  for t in "$runs"/*/timings.tsv; do
    [ -f "$t" ] || continue
    row="$(awk -F '\t' -v n="$name" '$3 == "Agent" && $4 == n { e = $1 } END { print e }' "$t")"
    epoch="$(printf '%s' "$row" | tr -cd '0-9')"
    [ -n "$epoch" ] || continue
    [ $((now - epoch)) -le 900 ] || continue
    if [ "$epoch" -gt "$best_epoch" ]; then best_epoch="$epoch"; best="$(dirname "$t")"; fi
  done
  [ -n "$best" ] || exit 0
  d="$best"
  printf '%s\n%s\n' "$now" "$agent_id" > "$d/worker-start-$name.txt"
}

# The files a phase is read from, relative to the scratch dir.
required_files() {
  case "$name" in
    ship-review) echo review-findings.md ;;
    ship-perf) echo perf-findings.md ;;
    ship-security) echo security-findings.md ;;
    ship-test-*) echo "generated-tests-${name#ship-test-}.md"; echo "worker-status-${name#ship-test-}.md" ;;
    ship-remediation-verify) echo remediation-verify.md ;;
  esac
}

cmd_stop() {
  local scratch start f missing=""
  scratch="$(scratch_of_agent)"
  [ -n "$scratch" ] || exit 0
  start="$scratch/worker-start-$name.txt"
  if [ "$(json_bool stop_hook_active)" = "true" ]; then
    date -u +%s > "$scratch/worker-done-$name.txt"
    exit 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$scratch/$f" ] || [ -z "$(find "$scratch/$f" -newer "$start" 2>/dev/null)" ]; then
      missing="$missing $scratch/$f"
    fi
  done < <(required_files)
  if [ -z "$missing" ]; then
    date -u +%s > "$scratch/worker-done-$name.txt"
    exit 0
  fi
  {
    echo "Ship: you were dispatched by the pipeline, which reads your result from disk, and these files were not written during this run:"
    for f in $missing; do echo "  - $f"; done
    echo "Write them now, in the format your prompt gives, then finish."
  } >&2
  exit 2
}

cmd_guard() {
  case "$name" in ship-test-*) ;; *) exit 0 ;; esac
  local scratch brief path rel
  scratch="$(scratch_of_agent)"
  [ -n "$scratch" ] || exit 0
  brief="$scratch/test-brief-${name#ship-test-}.md"
  [ -f "$brief" ] || exit 0
  path="$(json_field file_path)"
  [ -n "$path" ] || exit 0
  rel="${path#"$cwd"/}"
  rel="${rel#./}"
  if awk -v p="$rel" '
      /^## / { inlist = ($0 == "## Denylist"); next }
      inlist && /^- / { e = substr($0, 3); sub(/[[:space:]]+$/, "", e); if (e == p) found = 1 }
      END { exit(found ? 0 : 1) }' "$brief"; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Ship: %s is source under test — it is on the Denylist in %s. Test workers write tests only; report the problem instead of changing the source."}}\n' "$rel" "$brief"
  fi
  exit 0
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  guard) cmd_guard ;;
  *) exit 0 ;;
esac
