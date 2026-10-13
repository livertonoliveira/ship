#!/usr/bin/env bash

set -euo pipefail

# `graph.sh run` is the coordinator's loop as a script: it takes every step a
# script can take and returns only for the ones that need judgment. These tests
# drive whole graphs through it with a driver that starts its own workers, the
# way a runtime-backed one does, and no model anywhere.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

field() {
  printf '%s\n' "$1" | grep "^$2=" | head -1 | sed "s/^$2=//"
}

# A driver whose dispatch leaves a worker behind. The "worker" is the next
# `wait`: that is where each dispatched node finishes, asks or stays quiet,
# by what behavior-<task>.txt says. Every verb is appended to calls.log.
write_fake_driver() {
  cat > "$1/hooks/driver-fake.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
verb="${1:-}"; shift || true
STATE="" TASK="" UNTIL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --base|--repo|--timeout-ms) shift 2 ;;
    --until-file) UNTIL+=("$2"); shift 2 ;;
    *) [ -n "$TASK" ] || TASK="$1"; shift ;;
  esac
done
[ -z "$STATE" ] || printf '%s %s\n' "$verb" "$TASK" >> "$STATE/calls.log"
behavior() { cat "$STATE/behavior-$1.txt" 2>/dev/null || echo finish; }
case "$verb" in
  probe)
    printf 'starts_worker=1\nready=1\npriority=90\nworkspaces=fake\nreason=test double\n' ;;
  dispatch)
    [ "$(behavior "$TASK")" != "crash" ] || exit 1
    if [ "$(behavior "$TASK")" = "refuse" ]; then
      printf 'ok=0\nreason=the runtime refused %s\n' "$TASK"
      exit 1
    fi
    root="$(git rev-parse --show-toplevel)"
    git -C "$root" worktree add -q "$root/wt-$TASK" -b "ship/$TASK" main
    printf 'export const x = 1\n' > "$root/wt-$TASK/$TASK.ts"
    git -C "$root/wt-$TASK" add -A
    git -C "$root/wt-$TASK" commit -qm "feat: $TASK"
    printf 'worktree=%s\nbranch=%s\n' "$root/wt-$TASK" "ship/$TASK" > "$STATE/driver-fake-$TASK.txt"
    printf 'ok=1\n' ;;
  collect)
    [ "$(behavior "$TASK")" = "lost" ] || cat "$STATE/driver-fake-$TASK.txt" ;;
  wait)
    for f in "$STATE"/driver-fake-*.txt; do
      [ -f "$f" ] || continue
      t="$(basename "$f" .txt)"; t="${t#driver-fake-}"
      wt="$(sed -n 's/^worktree=//p' "$f")"
      scratch="$wt/.context/ship-run/$t"
      [ -d "$scratch" ] || continue
      [ -f "$scratch/homolog-approved.txt" ] && continue
      case "$(behavior "$t")" in
        finish) printf 'approved\n' > "$scratch/homolog-approved.txt" ;;
        ask) [ -f "$scratch/asked.txt" ] || { printf 'state=node-question\nquestion=keep the old column?\n' > "$scratch/ask.md"; : > "$scratch/asked.txt"; } ;;
        hold) ;;
      esac
    done
    printf 'timeout=1\n' ;;
  resume)
    printf 'finish\n' > "$STATE/behavior-$TASK.txt"
    printf 'ok=1\n' ;;
  *) printf 'ok=1\n' ;;
esac
DRIVER
}

# TASK-001 is the root; 002 and 003 depend on it.
new_sandbox() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/hooks" "$root/repo"
  cp "$HOOKS_SRC"/*.sh "$root/hooks/"
  local d
  for d in "$root/hooks"/driver-*.sh; do
    case "$(basename "$d")" in driver-local.sh|driver-manual.sh) ;; *) rm -f "$d" ;; esac
  done
  write_fake_driver "$root"
  (
    cd "$root/repo"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    mkdir -p ship
    printf -- '- Test Framework: none\n- Package Manager: none\n' > ship/config.md
    cat > nodes.json <<'JSON'
[ { "id": "TASK-001", "title": "Schema", "deps": [], "files": ["src/db/schema.ts"] },
  { "id": "TASK-002", "title": "Endpoint", "deps": ["TASK-001"], "files": ["src/api/routes.ts"] },
  { "id": "TASK-003", "title": "Tela", "deps": ["TASK-001"], "files": ["src/web/checkout.tsx"] } ]
JSON
    bash "$root/hooks/graph.sh" init --feature f --from nodes.json --driver "${2:-fake}" --max-in-flight 2 --base-branch main --mode local >/dev/null
  )
  printf '%s' "$root"
}

run_graph() {
  local root="$1"; shift
  ( cd "$root/repo" && SHIP_GRAPH_RUN_IDLE_S=1 SHIP_GRAPH_RUN_LANDED_POLL_S=0 bash "$root/hooks/graph.sh" run "$@" 2>&1 )
}

state_dir() { printf '%s/repo/.context/ship-graph/f' "$1"; }

status_of() {
  awk -F'\t' -v t="$2" '$1 == t { print $6 }' "$(state_dir "$1")/nodes.tsv"
}

calls() {
  grep -c "^$2\$" "$(state_dir "$1")/calls.log" 2>/dev/null || true
}

test_run_takes_a_graph_to_done_alone() {
  local name="one run call dispatches, waits, polls and ends the graph, each node dispatched once"
  local root out
  root="$(new_sandbox)"
  out="$(run_graph "$root")"
  if [ "$(field "$out" action)" = "done" ] \
     && [ "$(status_of "$root" TASK-001)" = "merged" ] \
     && [ "$(status_of "$root" TASK-002)" = "merged" ] \
     && [ "$(status_of "$root" TASK-003)" = "merged" ] \
     && [ "$(calls "$root" 'dispatch TASK-001')" = "1" ] \
     && [ "$(calls "$root" 'dispatch TASK-002')" = "1" ] \
     && [ "$(calls "$root" 'dispatch TASK-003')" = "1" ] \
     && [ ! -e "$(state_dir "$root")/run.lock" ] \
     && [ ! -e "$(state_dir "$root")/run-heartbeat.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (out: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
  rm -rf "$root"
}

test_run_returns_for_a_node_question_and_resumes_after_the_answer() {
  local name="a node's question is the executor's: run returns with it, and the next run finishes the graph"
  local root out again
  root="$(new_sandbox)"
  printf 'ask\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  out="$(run_graph "$root")"
  ( cd "$root/repo" && bash "$root/hooks/graph.sh" answer TASK-001 "keep it — the migration reads it" >/dev/null 2>&1 )
  again="$(run_graph "$root")"
  if [ "$(field "$out" action)" = "answer" ] \
     && printf '%s' "$out" | grep -q 'TASK-001 asks: keep the old column?' \
     && printf '%s' "$out" | grep -q 'Then run: bash ".*/graph.sh" run$' \
     && [ "$(field "$again" action)" = "done" ] \
     && [ "$(calls "$root" 'dispatch TASK-001')" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (first: $(printf '%s' "$out" | tr '\n' '|'), second: $(field "$again" action))"
  fi
  rm -rf "$root"
}

test_run_closes_its_slice_and_asks_to_be_called_again() {
  local name="a slice that closes with work in flight returns action=run and releases the graph"
  local root out
  root="$(new_sandbox)"
  printf 'hold\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  out="$(run_graph "$root" --slice 3)"
  if [ "$(field "$out" action)" = "run" ] \
     && [ "$(field "$out" state)" = "running" ] \
     && printf '%s' "$out" | grep -q 'graph.sh" run ' \
     && [ "$(status_of "$root" TASK-001)" = "in_flight" ] \
     && [ ! -e "$(state_dir "$root")/run.lock" ] \
     && [ -s "$(state_dir "$root")/run-heartbeat.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (out: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
  rm -rf "$root"
}

test_a_newer_run_takes_the_graph_over() {
  local name="a second run makes the first step down, which says so and is not to be restarted; the node is dispatched once"
  local root first second
  root="$(new_sandbox)"
  printf 'hold\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  run_graph "$root" > "$root/first.out" &
  local first_pid=$!
  local i=0
  while [ "$(status_of "$root" TASK-001)" != "in_flight" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
  printf 'finish\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  second="$(run_graph "$root")"
  wait "$first_pid" 2>/dev/null || true
  first="$(cat "$root/first.out")"
  if [ "$(field "$first" state)" = "superseded" ] \
     && [ "$(field "$first" action)" = "none" ] \
     && printf '%s' "$first" | grep -q 'Do NOT start run again' \
     && printf '%s' "$second" | grep -q 'run: taking the graph over from run pid' \
     && [ "$(field "$second" action)" = "done" ] \
     && [ "$(calls "$root" 'dispatch TASK-001')" = "1" ] \
     && [ ! -e "$(state_dir "$root")/run.lock" ]; then
    log_pass "$name"
  else
    log_fail "$name (first: $(printf '%s' "$first" | tr '\n' '|'), second: $(field "$second" action), dispatches: $(calls "$root" 'dispatch TASK-001'))"
  fi
  rm -rf "$root"
}

test_a_stale_lock_is_not_a_process_to_signal() {
  local name="a lock whose pid is alive but is not a run is replaced, and that process is left alone"
  local root out bystander
  root="$(new_sandbox)"
  sleep 120 &
  bystander=$!
  mkdir -p "$(state_dir "$root")/run.lock"
  printf '%s\n' "$bystander" > "$(state_dir "$root")/run.lock/pid"
  out="$(run_graph "$root")"
  if [ "$(field "$out" action)" = "done" ] && kill -0 "$bystander" 2>/dev/null; then
    log_pass "$name"
  else
    log_fail "$name (action: $(field "$out" action), bystander alive: $(kill -0 "$bystander" 2>/dev/null && echo yes || echo no))"
  fi
  kill "$bystander" 2>/dev/null || true
  wait "$bystander" 2>/dev/null || true
  rm -rf "$root"
}

test_a_stopped_run_releases_the_graph() {
  local name="a run that is stopped exits and releases the graph; nothing in flight is touched"
  local root pid i=0
  root="$(new_sandbox)"
  printf 'hold\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  run_graph "$root" > "$root/first.out" &
  while [ "$(status_of "$root" TASK-001)" != "in_flight" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
  pid="$(cat "$(state_dir "$root")/run.lock/pid" 2>/dev/null || true)"
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -e "$(state_dir "$root")/run.lock" ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
  wait 2>/dev/null || true
  if [ -n "$pid" ] && [ ! -e "$(state_dir "$root")/run.lock" ] && [ "$(status_of "$root" TASK-001)" = "in_flight" ]; then
    log_pass "$name"
  else
    log_fail "$name (pid: $pid, lock: $(ls -d "$(state_dir "$root")/run.lock" 2>/dev/null || echo released), status: $(status_of "$root" TASK-001))"
  fi
  rm -rf "$root"
}

test_a_driver_that_cannot_start_workers_gets_the_dispatch_back() {
  local name="with a driver whose worker only the caller can launch, run hands the dispatch step back untouched"
  local root out
  root="$(new_sandbox "" local)"
  out="$(run_graph "$root")"
  if [ "$(field "$out" action)" = "dispatch" ] \
     && [ "$(field "$out" frontier)" = "TASK-001" ] \
     && printf '%s' "$out" | grep -q 'driver-local.sh" dispatch TASK-001' \
     && printf '%s' "$out" | grep -q 'run: bash ".*/graph.sh" run — do not evaluate' \
     && [ "$(status_of "$root" TASK-001)" = "pending" ] \
     && [ ! -e "$(state_dir "$root")/run.lock" ]; then
    log_pass "$name"
  else
    log_fail "$name (out: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
  rm -rf "$root"
}

test_a_refused_dispatch_claims_nothing() {
  local name="a dispatch the driver refuses leaves the node unclaimed and the loop alive"
  local root out
  root="$(new_sandbox)"
  printf 'refuse\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  out="$(run_graph "$root" --slice 2)"
  if [ "$(field "$out" action)" = "run" ] \
     && printf '%s' "$out" | grep -q 'run: TASK-001 not dispatched — the runtime refused TASK-001' \
     && [ "$(status_of "$root" TASK-001)" = "pending" ]; then
    log_pass "$name"
  else
    log_fail "$name (out: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
  rm -rf "$root"
}

test_a_dispatch_that_cannot_be_collected_is_counted() {
  local name="a worker the driver started but cannot locate is counted as a failed dispatch, not retried in silence"
  local root out
  root="$(new_sandbox)"
  printf 'lost\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  out="$(run_graph "$root" --slice 2 || true; run_graph "$root" --slice 1 || true)"
  if grep -q 'TASK-001 dispatch failed (1 of 5): the driver started TASK-001 but could not say where' "$(state_dir "$root")/graph-log.md" \
     && [ "$(status_of "$root" TASK-001)" != "in_flight" ]; then
    log_pass "$name"
  else
    log_fail "$name (out: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
  rm -rf "$root"
}

test_a_dispatch_that_dies_silently_is_capped() {
  local name="a dispatch that dies without an answer is counted, and past the cap the node fails instead of being retried forever"
  local root out
  root="$(new_sandbox)"
  printf 'crash\n' > "$(state_dir "$root")/behavior-TASK-001.txt"
  out="$(run_graph "$root" --slice 60)"
  if [ "$(field "$out" action)" = "done" ] \
     && [ "$(status_of "$root" TASK-001)" = "failed" ] \
     && [ "$(calls "$root" 'dispatch TASK-001')" = "5" ] \
     && grep -q 'TASK-001 → failed: dispatch failed 5 of 5 time(s) — last: the driver exited without reporting a dispatch for TASK-001' "$(state_dir "$root")/graph-log.md"; then
    log_pass "$name"
  else
    log_fail "$name (action: $(field "$out" action), status: $(status_of "$root" TASK-001), dispatches: $(calls "$root" 'dispatch TASK-001'))"
  fi
  rm -rf "$root"
}

test_next_called_directly_still_names_next() {
  local name="next called by hand keeps pointing at next — only run rewrites the loop command"
  local root out
  root="$(new_sandbox)"
  out="$(cd "$root/repo" && bash "$root/hooks/graph.sh" next 2>/dev/null)"
  if printf '%s' "$out" | grep -q 'run: bash ".*/graph.sh" next — do not evaluate'; then
    log_pass "$name"
  else
    log_fail "$name (out: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
  rm -rf "$root"
}

test_run_takes_a_graph_to_done_alone
test_run_returns_for_a_node_question_and_resumes_after_the_answer
test_run_closes_its_slice_and_asks_to_be_called_again
test_a_newer_run_takes_the_graph_over
test_a_stale_lock_is_not_a_process_to_signal
test_a_stopped_run_releases_the_graph
test_a_driver_that_cannot_start_workers_gets_the_dispatch_back
test_a_refused_dispatch_claims_nothing
test_a_dispatch_that_cannot_be_collected_is_counted
test_a_dispatch_that_dies_silently_is_capped
test_next_called_directly_still_names_next

echo ""
echo "Results: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
