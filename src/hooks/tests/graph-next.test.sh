#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"
DRIVER_MANUAL="$SCRIPT_DIR/../driver-manual.sh"

pass_count=0
fail_count=0

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

# A repo with a graph of four nodes:
#   TASK-001            (root)
#   TASK-002 ← 001      files src/api/routes.ts
#   TASK-003 ← 001      files src/web/checkout.tsx
#   TASK-004 ← 001      files src/api          (conflicts with 002 by prefix)
setup_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    mkdir -p ship
    printf -- '- Test Framework: none\n- Package Manager: none\n' > ship/config.md
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-001", "title": "Schema", "deps": [], "files": ["src/db/schema.ts"] },
  { "id": "TASK-002", "repo": "api", "title": "Endpoint", "deps": ["TASK-001"], "files": ["src/api/routes.ts"] },
  { "id": "TASK-003", "title": "Tela", "deps": ["TASK-001"], "files": ["src/web/checkout.tsx"] },
  { "id": "TASK-004", "title": "Rota extra", "deps": ["TASK-001"], "files": ["src/api"] }
]
EOF
  )
}

field() {
  printf '%s\n' "$1" | grep "^$2=" | head -1 | sed "s/^$2=//"
}

# A workspace for <task> with one commit, so the graph has a real branch to
# open a PR from and a real footprint to read.
make_workspace() {
  local dir="$1" task="$2" file="$3"
  (
    cd "$dir"
    git worktree add -q "wt-$task" -b "ship/$task" main
    mkdir -p "wt-$task/$(dirname "$file")"
    printf 'export const x = 1\n' > "wt-$task/$file"
    git -C "wt-$task" add -A
    git -C "wt-$task" commit -qm "feat: $task"
  )
}

test_claim_marks_the_workspace_as_having_a_coordinator() {
  local name="claim tells the node's pipeline it has a coordinator to post questions to"
  local dir
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  if [ -s "$dir/wt-TASK-001/.context/ship-run/TASK-001/graph-node.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (no graph-node.txt in the claimed workspace)"
  fi
  rm -rf "$dir"
}

test_a_nodes_question_reaches_the_coordinator() {
  local name="a question a node posts is surfaced by next, and answer clears it and unfreezes the stall counter"
  local dir out scratch answered
  dir="$(mktemp -d)"
  setup_repo "$dir"
  scratch="$dir/wt-TASK-001/.context/ship-run/TASK-001"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'state=gate\nquestion=medium findings, continue?\ndetail:\nfull text\n' \
      > .context/ship-graph/f/../../../wt-TASK-001/.context/ship-run/TASK-001/ask.md 2>/dev/null \
      || printf 'state=gate\nquestion=medium findings, continue?\ndetail:\nfull text\n' \
        > "wt-TASK-001/.context/ship-run/TASK-001/ask.md"
    # The node looks stalled while it waits — the counter must not outlive the answer.
    printf '3\n' > .context/ship-graph/f/stall-TASK-001.txt
  )
  out="$(cd "$dir" && bash "$GRAPH" next 2>/dev/null || true)"
  answered="$(cd "$dir" && bash "$GRAPH" answer TASK-001 proceed 2>&1 || true)"

  if [ "$(field "$out" action)" = "ask" ] \
    && printf '%s' "$out" | grep -q 'medium findings, continue?' \
    && printf '%s' "$out" | grep -q 'graph.sh" answer <task> <answer>' \
    && [ "$(field "$answered" answered)" = "TASK-001" ] \
    && [ "$(head -1 "$scratch/answer.txt")" = "proceed" ] \
    && [ ! -f "$scratch/ask.md" ] \
    && [ ! -f "$dir/.context/ship-graph/f/stall-TASK-001.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (action=$(field "$out" action) answered=$(field "$answered" answered))"
  fi
  rm -rf "$dir"
}

test_answer_refuses_a_node_with_no_pending_question() {
  local name="answer refuses a node that asked nothing, instead of planting an answer for a future gate"
  local dir rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  (cd "$dir" && bash "$GRAPH" answer TASK-001 proceed >/dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -f "$dir/wt-TASK-001/.context/ship-run/TASK-001/answer.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (exit $rc)"
  fi
  rm -rf "$dir"
}

test_poll_lands_on_the_completion_artifact_not_a_handshake() {
  local name="poll lands a node from homolog-approved.txt — no worker report needed"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'deferred\n' > "wt-TASK-001/.context/ship-run/TASK-001/homolog-approved.txt"
  )
  out="$(cd "$dir" && bash "$GRAPH" poll --stall-after 0)"
  local inflight
  inflight="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"status": "in_flight"' || true)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^landed=TASK-001$' && [ "$inflight" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' inflight_nodes=$inflight)"
  fi
}

test_poll_seals_uncommitted_work_into_the_branch() {
  local name="landing commits the workspace — develop never commits, so the branch would be empty"
  local dir commits
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    git worktree add -q wt-TASK-001 -b ship/TASK-001 main
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    # Exactly what /ship:run leaves behind: files written, nothing committed.
    mkdir -p wt-TASK-001/src/db
    printf 'export const s = 1\n' > wt-TASK-001/src/db/schema.ts
    printf 'deferred\n' > "wt-TASK-001/.context/ship-run/TASK-001/homolog-approved.txt"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
  )
  commits="$(git -C "$dir/wt-TASK-001" rev-list --count main..ship/TASK-001 2>/dev/null || echo 0)"
  local has_file=0
  git -C "$dir" show "ship/TASK-001:src/db/schema.ts" >/dev/null 2>&1 && has_file=1
  rm -rf "$dir"

  if [ "$commits" -ge 1 ] && [ "$has_file" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (commits=$commits file_in_branch=$has_file)"
  fi
}

test_poll_reports_progress_without_landing() {
  local name="a node still working reports working=, and is not landed"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
  )
  out="$(cd "$dir" && bash "$GRAPH" poll --stall-after 0)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^working=TASK-001$' && ! printf '%s' "$out" | grep -q '^landed='; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_stalled_node_is_resumed_retried_then_reported() {
  local name="a node with no phase progress is resumed, then retried in a fresh workspace, then reported failed — never an endless wait, never a question"
  local dir out_after_resume out_after_fail out_final attempts log
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    # The first poll after a claim reads the dispatch-log row as progress, so
    # the stall count starts on the second: resume on the 4th poll, fail three
    # quiet polls after that.
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" next > next1.txt
    bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" next > next2.txt
    # The retry: a second claim in a fresh workspace, quiet again.
    git worktree add -q wt2-TASK-001 -b ship/TASK-001-r2 main
    bash "$GRAPH" claim TASK-001 --worktree "wt2-TASK-001" --branch ship/TASK-001-r2 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt2-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" next > next3.txt
  )
  out_after_resume="$(cat "$dir/next1.txt")"
  out_after_fail="$(cat "$dir/next2.txt")"
  out_final="$(cat "$dir/next3.txt")"
  attempts="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"attempts": 2' || true)"
  log="$dir/.context/ship-graph/f/graph-log.md"
  local resumed retried
  resumed="$(grep -c 'worker resumed once' "$log" || true)"
  retried="$(grep -c 'automatic retry 2 of 2' "$log" || true)"
  rm -rf "$dir"

  if [ "$(field "$out_after_resume" action)" = "wait" ] \
    && [ "$(field "$out_after_fail" action)" = "dispatch" ] && printf '%s' "$out_after_fail" | grep -q 'TASK-001' \
    && [ "$(field "$out_final" state)" = "done" ] && [ "$(field "$out_final" action)" = "done" ] \
    && printf '%s' "$out_final" | grep -q 'Failed: TASK-001' \
    && [ "$resumed" = "2" ] && [ "$retried" = "1" ] && [ "$attempts" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (after-resume=$(field "$out_after_resume" action) after-fail=$(field "$out_after_fail" action) final=$(field "$out_final" state)/$(field "$out_final" action) resumed=$resumed retried=$retried attempts2=$attempts)"
  fi
}

test_never_started_node_is_redispatched_within_the_cap() {
  local name="a worker that never started is returned to the frontier for a fresh dispatch, then failed once the cap is reached"
  local dir out1 out2
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    # No dispatch-log.md at all: the pipeline never ran a single phase.
    bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 > poll3.txt
    bash "$GRAPH" next > next1.txt
    git worktree add -q wt2-TASK-001 -b ship/TASK-001-r2 main
    bash "$GRAPH" claim TASK-001 --worktree "wt2-TASK-001" --branch ship/TASK-001-r2 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null; bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 > poll6.txt
  )
  out1="$(cat "$dir/poll3.txt")"
  out2="$(cat "$dir/poll6.txt")"
  local dispatch_again held
  dispatch_again="$(field "$(cat "$dir/next1.txt")" action)"
  held="$(cat "$dir/.context/ship-graph/f/hold-TASK-001.txt" 2>/dev/null || true)"
  rm -rf "$dir"
  if printf '%s' "$out1" | grep -q '^retried=TASK-001$' && [ "$dispatch_again" = "dispatch" ] \
    && printf '%s' "$out2" | grep -q '^failed=TASK-001$' \
    && printf '%s' "$held" | grep -q 'never started'; then
    log_pass "$name"
  else
    log_fail "$name (poll3='$out1' next=$dispatch_again poll6='$out2' hold='$held')"
  fi
}

test_a_failure_by_decision_is_never_retried() {
  local name="abort and fail leave a hold — the graph never retries a failure a person decided"
  local dir out held_abort held_fail
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main --node-pr off >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" abort >/dev/null
  )
  held_abort="$(cat "$dir/.context/ship-graph/f/hold-TASK-001.txt" 2>/dev/null || true)"
  out="$(cd "$dir" && bash "$GRAPH" next)"
  (cd "$dir" && bash "$GRAPH" reset TASK-001 >/dev/null && bash "$GRAPH" fail TASK-001 --reason "wrong scope" >/dev/null)
  held_fail="$(cat "$dir/.context/ship-graph/f/hold-TASK-001.txt" 2>/dev/null || true)"
  rm -rf "$dir"
  if [ -n "$held_abort" ] && [ "$(field "$out" state)" = "done" ] && [ "$(field "$out" action)" = "done" ] \
    && printf '%s' "$held_fail" | grep -q 'wrong scope'; then
    log_pass "$name"
  else
    log_fail "$name (hold_abort='$held_abort' next=$(field "$out" state)/$(field "$out" action) hold_fail='$held_fail')"
  fi
}

test_init_refuses_a_dependency_cycle() {
  local name="init refuses a dependency cycle before any workspace exists, naming the cycle"
  local dir out rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  printf '[\n { "id": "A-1", "title": "a", "deps": ["C-1"], "files": ["a"] },\n { "id": "B-1", "title": "b", "deps": ["A-1"], "files": ["b"] },\n { "id": "C-1", "title": "c", "deps": ["B-1"], "files": ["c"] },\n { "id": "D-1", "title": "d", "deps": [], "files": ["d"] }\n]\n' > "$dir/cyc.json"
  out="$(cd "$dir" && bash "$GRAPH" init --feature cyc --from cyc.json --driver manual --base-branch main 2>&1)" || rc=$?
  local left
  left="$(ls "$dir/.context/ship-graph/cyc" 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$dir"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'dependency cycle' \
    && printf '%s' "$out" | grep -qE 'A-1 -> C-1 -> B-1 -> A-1|C-1 -> B-1 -> A-1 -> C-1|B-1 -> A-1 -> C-1 -> B-1' \
    && [ "$left" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc out='$out' left=$left)"
  fi
}

test_progress_resets_the_stall_counter() {
  local name="a node that resumes phase progress clears its stall counter"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" action)" = "wait" ]; then
    log_pass "$name"
  else
    log_fail "$name (action='$(field "$out" action)', expected wait — the counter did not reset)"
  fi
}

test_tasks_md_parser_ignores_rules_and_prose() {
  local name="tasks.md parsing ignores --- rules and acceptance/Gherkin prose"
  local dir out
  dir="$(mktemp -d)"
  cat > "$dir/tasks.md" <<'EOF'
# Tasks

### TASK-001 — Somar

## Files
create src/add.js — funcao add
create src/add.test.js — testes

## Acceptance Criteria
- AC-01: add(2,2) retorna 4

## Scenarios

Scenario: soma simples
  Given dois numeros
  When somo
  Then retorna a soma

## Deps
none

---

### TASK-002 — Subtrair

## Files
create src/subtract.js — funcao subtract

## Deps
TASK-001

---
EOF
  out="$(bash "$GRAPH" nodes --from-tasks "$dir/tasks.md")"
  rm -rf "$dir"

  # "---" used to survive dep cleanup as a node id of "--", so every task
  # depended on a node that cannot exist and the graph deadlocked at once.
  if printf '%s' "$out" | grep -q '"deps": \[\]' \
    && printf '%s' "$out" | grep -q '"deps": \["TASK-001"\]' \
    && ! printf '%s' "$out" | grep -q '\-\-"' \
    && ! printf '%s' "$out" | grep -qi 'scenario\|given\|AC-01' \
    && printf '%s' "$out" | grep -q '"files": \["src/add.js", "src/add.test.js"\]'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_failed_init_leaves_no_debris() {
  local name="an init that fails validation leaves no partial graph behind"
  local dir rc=0 leftover
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    printf '[{ "id": "TASK-A", "title": "A", "deps": ["TASK-GHOST"], "files": ["a.ts"] }]\n' > bad.json
    bash "$GRAPH" init --feature f --from bad.json --driver manual --base-branch main >/dev/null 2>&1
  ) || rc=$?
  leftover="$(ls "$dir/.context/ship-graph/f" 2>/dev/null | tr '\n' ' ')"
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && [ -z "$(printf '%s' "$leftover" | tr -d ' ')" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc leftover='$leftover')"
  fi
}

test_corrected_init_after_a_failure_is_not_refused_as_resume() {
  local name="a corrected init after a failed one runs, instead of reporting RESUME over the debris"
  local dir out rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    printf '[{ "id": "TASK-A", "title": "A", "deps": ["TASK-GHOST"], "files": ["a.ts"] }]\n' > bad.json
    bash "$GRAPH" init --feature f --from bad.json --driver manual --base-branch main >/dev/null 2>&1 || true
  )
  out="$(cd "$dir" && bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main 2>&1)" || rc=$?
  local nodes
  nodes="$(cd "$dir" && bash "$GRAPH" status --json 2>/dev/null | grep -c '"status": "pending"')"
  rm -rf "$dir"

  # The trap this closes: RESUME fired on a half-written directory, so the fix
  # could never be applied and only --fresh cleared it — the exact reflex the
  # RESUME contract exists to prevent.
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^INIT ' && [ "$nodes" = "4" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc nodes=$nodes out='$out')"
  fi
}

test_init_seals_the_spec_onto_the_base() {
  local name="init commits ship/changes/<feature> so node workspaces inherit the spec"
  local dir in_branch=0 in_worktree=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    # Exactly what /ship:spec leaves behind: written, never committed.
    mkdir -p ship/changes/f
    printf '# Tasks\n\n### TASK-001 — Somar\n' > ship/changes/f/tasks.md
    printf '# Proposal\n' > ship/changes/f/proposal.md
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main --mode local >/dev/null
    git worktree add -q --detach wt-check main >/dev/null 2>&1
  )
  git -C "$dir" show "HEAD:ship/changes/f/tasks.md" >/dev/null 2>&1 && in_branch=1
  [ -f "$dir/wt-check/ship/changes/f/tasks.md" ] && in_worktree=1
  rm -rf "$dir"

  # The bug this closes: a node workspace branched from the base found no spec,
  # so its pipeline stopped at the context state with nothing to read.
  if [ "$in_branch" -eq 1 ] && [ "$in_worktree" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (committed=$in_branch visible_in_new_workspace=$in_worktree)"
  fi
}

test_init_seal_is_idempotent_and_scoped() {
  local name="sealing commits only the spec dir, and re-running adds no empty commit"
  local dir before after untouched=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    mkdir -p ship/changes/f
    printf '# Tasks\n' > ship/changes/f/tasks.md
    printf 'stray\n' > unrelated.txt
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main --mode local >/dev/null
  )
  before="$(git -C "$dir" rev-list --count HEAD)"
  (cd "$dir" && bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main --mode local >/dev/null 2>&1) || true
  after="$(git -C "$dir" rev-list --count HEAD)"
  git -C "$dir" show "HEAD:unrelated.txt" >/dev/null 2>&1 || untouched=1
  rm -rf "$dir"

  if [ "$before" = "$after" ] && [ "$untouched" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (commits $before → $after, unrelated_file_left_out=$untouched)"
  fi
}

test_abort_stops_workers_and_keeps_workspaces() {
  local name="abort marks in-flight nodes failed, keeps their workspaces, and is visible in the log"
  local dir out kept=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" abort --reason "operator killed the run")"
  local status logged
  status="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"status": "failed"')"
  logged="$(grep -c 'worker stopped' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null || echo 0)"
  [ -d "$dir/wt-TASK-001" ] && kept=1
  rm -rf "$dir"

  # Workspaces must survive: a stopped node's work is what you inspect before
  # deciding to retry or drop it.
  if printf '%s' "$out" | grep -q '^stopped=TASK-001$' \
    && printf '%s' "$out" | grep -q '^aborted=1$' \
    && [ "$status" = "1" ] && [ "$kept" -eq 1 ] && [ "$logged" -ge 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (status_failed=$status kept=$kept logged=$logged out='$out')"
  fi
}

test_abort_is_a_noop_with_nothing_in_flight() {
  local name="abort with no in-flight node reports zero and changes nothing"
  local dir out pending
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (cd "$dir" && bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null)
  out="$(cd "$dir" && bash "$GRAPH" abort)"
  pending="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"status": "pending"')"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^aborted=0$' && [ "$pending" = "4" ]; then
    log_pass "$name"
  else
    log_fail "$name (aborted count wrong, or nodes changed: pending=$pending)"
  fi
}

test_every_driver_answers_stop() {
  local name="every driver answers the stop verb"
  local dir ok=1 d out
  dir="$(mktemp -d)"
  for d in manual local; do
    out="$(bash "$SCRIPT_DIR/../driver-$d.sh" stop TASK-001 --state "$dir" 2>&1)" || ok=0
    printf '%s\n' "$out" | grep -q '^stopped=TASK-001$' || ok=0
  done
  rm -rf "$dir"

  if [ "$ok" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_guard_catches_a_driver_missing_stop() {
  local name="the isolation guard fails when a driver lacks the stop verb"
  local root rc=0
  root="$(mktemp -d)"
  mkdir -p "$root/src/hooks" "$root/src/skills/graph" "$root/scripts"
  cp "$REPO_ROOT/src/hooks/graph.sh" "$root/src/hooks/graph.sh"
  cp "$REPO_ROOT/src/skills/graph/SKILL.md" "$root/src/skills/graph/SKILL.md"
  cp "$REPO_ROOT/scripts/check-graph-driver-isolation.sh" "$root/scripts/"
  printf '#!/usr/bin/env bash\nverb_dispatch() { :; }\nverb_collect() { :; }\nverb_wait() { :; }\nverb_ask() { :; }\n' \
    > "$root/src/hooks/driver-nostop.sh"

  GRAPH_ISOLATION_ROOT="$root" bash "$root/scripts/check-graph-driver-isolation.sh" >/dev/null 2>&1 || rc=$?
  rm -rf "$root"

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (guard accepted a driver with no stop verb)"
  fi
}

test_poll_writes_progress_to_the_log() {
  local name="poll records progress in graph-log.md, resumes a quiet node once, then fails it"
  local dir working resumed failed_line status out4 out7
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 > poll4.txt
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 > poll7.txt
  )
  out4="$(cat "$dir/poll4.txt")"
  out7="$(cat "$dir/poll7.txt")"
  working="$(grep -c 'working —' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null || echo 0)"
  resumed="$(grep -c 'worker resumed once' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null || echo 0)"
  failed_line="$(grep -c 'failed: no phase progress' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null || echo 0)"
  status="$(cd "$dir" && bash "$GRAPH" status | awk '$1 == "TASK-001" { print $2 }')"
  rm -rf "$dir"

  # A quiet node is nudged through the driver exactly once — its answer or its
  # next step is on disk and the worker just stopped looking — and only a node
  # that stays quiet after that is failed, with the run continuing without it.
  if [ "$working" -ge 1 ] && [ "$resumed" = "1" ] && [ "$failed_line" = "1" ] \
    && printf '%s' "$out4" | grep -q '^resumed=TASK-001$' \
    && printf '%s' "$out7" | grep -q '^failed=TASK-001$' \
    && [ "$status" = "failed" ]; then
    log_pass "$name"
  else
    log_fail "$name (working=$working resumed=$resumed failed=$failed_line status=$status)"
  fi
}

test_answer_wakes_the_worker_through_the_driver() {
  local name="answer writes the file AND resumes the worker through the driver — the file alone wakes nobody"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'state=gate\nquestion=q\ndetail:\nd\n' > "wt-TASK-001/.context/ship-run/TASK-001/ask.md"
  )
  out="$(cd "$dir" && bash "$GRAPH" answer TASK-001 defer 2>&1)"
  rm -rf "$dir"
  if printf '%s' "$out" | grep -q '^resumed=' \
    && printf '%s' "$out" | grep -q '^instruction=Tell the agent working on TASK-001' \
    && printf '%s' "$out" | grep -q 'answer.txt'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_batch_admission_holds_a_freed_slot() {
  local name="admission=batch keeps a freed slot empty until every in-flight node has closed"
  local dir out_batch out_stream
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main --node-pr off >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'deferred\n' > "wt-TASK-001/.context/ship-run/TASK-001/homolog-approved.txt"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" next >/dev/null
    make_workspace "$dir" TASK-002 src/api/routes.ts
    bash "$GRAPH" claim TASK-002 --worktree "wt-TASK-002" --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" set --admission batch >/dev/null
  )
  out_batch="$(cd "$dir" && bash "$GRAPH" next)"
  (cd "$dir" && bash "$GRAPH" set --admission stream >/dev/null)
  out_stream="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"
  # One slot is free either way; only stream fills it while TASK-002 is in flight.
  if [ "$(field "$out_batch" action)" = "wait" ] && [ -z "$(field "$out_batch" frontier)" ] \
    && [ "$(field "$out_stream" action)" = "dispatch" ] && [ -n "$(field "$out_stream" frontier)" ]; then
    log_pass "$name"
  else
    log_fail "$name (batch=$(field "$out_batch" action)/'$(field "$out_batch" frontier)' stream=$(field "$out_stream" action)/'$(field "$out_stream" frontier)')"
  fi
}

test_a_failed_node_does_not_freeze_the_run() {
  local name="a failed node holds only its dependents — the rest of the frontier keeps dispatching"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main --node-pr off >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'deferred\n' > "wt-TASK-001/.context/ship-run/TASK-001/homolog-approved.txt"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" next >/dev/null
    make_workspace "$dir" TASK-002 src/api/routes.ts
    bash "$GRAPH" claim TASK-002 --worktree "wt-TASK-002" --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" fail TASK-002 --reason "broken" >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"
  if [ "$(field "$out" action)" = "dispatch" ] && printf '%s' "$out" | grep -q 'TASK-003'; then
    log_pass "$name"
  else
    log_fail "$name (action=$(field "$out" action) frontier='$(field "$out" frontier)')"
  fi
}

test_a_run_ending_with_failures_reports_them_once() {
  local name="when nothing can run and some nodes failed past their attempts, next ends the run with the failed list — not a question"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 4 --base-branch main --node-pr off >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" fail TASK-001 --reason "plan invalid" >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"
  if [ "$(field "$out" state)" = "done" ] && [ "$(field "$out" action)" = "done" ] \
    && printf '%s' "$out" | grep -q 'Failed: TASK-001' \
    && printf '%s' "$out" | grep -q 'reset'; then
    log_pass "$name"
  else
    log_fail "$name (state=$(field "$out" state) action=$(field "$out" action))"
  fi
}

test_poll_fails_a_node_from_its_own_verdict() {
  local name="poll fails a node whose pipeline left node-failed.txt — without waiting for the stall cap"
  local dir out status reason
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'plan failed validation after retries\n' > "wt-TASK-001/.context/ship-run/TASK-001/node-failed.txt"
  )
  out="$(cd "$dir" && bash "$GRAPH" poll --stall-after 0)"
  status="$(cd "$dir" && bash "$GRAPH" status | awk '$1 == "TASK-001" { print $2 }')"
  reason="$(grep -c 'plan failed validation after retries' "$dir/.context/ship-graph/f/graph-log.md" || true)"
  rm -rf "$dir"
  if printf '%s' "$out" | grep -q '^failed=TASK-001$' && [ "$status" = "failed" ] && [ "$reason" -ge 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' status=$status)"
  fi
}

test_next_refreshes_stale_conflict_edges_itself() {
  local name="next clears a conflict edge whose holder already merged — no separate conflicts call needed"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main --node-pr off >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf 'deferred\n' > "wt-TASK-001/.context/ship-run/TASK-001/homolog-approved.txt"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    # 002 and 004 overlap on src/api; 002 takes the slot, 004 is recorded as blocked by it.
    bash "$GRAPH" next >/dev/null
    make_workspace "$dir" TASK-002 src/api/routes.ts
    bash "$GRAPH" claim TASK-002 --worktree "wt-TASK-002" --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" conflicts >/dev/null
    printf 'deferred\n' > "wt-TASK-002/.context/ship-run/TASK-002/homolog-approved.txt"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
  )
  # TASK-002 is merged (no forge) and TASK-004 still carries blocked_by_conflict=TASK-002
  # in the state file. A next that trusted it would find nothing to dispatch.
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"
  if [ "$(field "$out" action)" = "dispatch" ] && printf '%s' "$out" | grep -q 'TASK-004'; then
    log_pass "$name"
  else
    log_fail "$name (action=$(field "$out" action) frontier='$(field "$out" frontier)')"
  fi
}

test_seal_keeps_shared_tasks_md_out_of_node_commits() {
  local name="sealing excludes the shared tasks.md, which every node edits"
  local dir has_code=0 has_tasks=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    mkdir -p ship/changes/f
    printf '# Tasks\n\n### TASK-001 — a\n' > ship/changes/f/tasks.md
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main --mode local >/dev/null
    git worktree add -q wt-TASK-001 -b ship/TASK-001 main
    bash "$GRAPH" claim TASK-001 --worktree wt-TASK-001 --branch ship/TASK-001 >/dev/null
    mkdir -p wt-TASK-001/src/db
    printf 'export const s = 1\n' > wt-TASK-001/src/db/schema.ts
    # What a node really leaves behind: its own code plus an edit to the shared
    # tasks.md marking itself done.
    printf '# Tasks\n\n### TASK-001 — a (done)\n' > wt-TASK-001/ship/changes/f/tasks.md
    printf 'deferred\n' > wt-TASK-001/.context/ship-run/TASK-001/homolog-approved.txt
    bash "$GRAPH" poll --stall-after 0 >/dev/null
  )
  git -C "$dir" show "ship/TASK-001:src/db/schema.ts" >/dev/null 2>&1 && has_code=1
  git -C "$dir" diff --quiet main ship/TASK-001 -- ship/changes/f/tasks.md 2>/dev/null && has_tasks=0 || has_tasks=1
  rm -rf "$dir"

  if [ "$has_code" -eq 1 ] && [ "$has_tasks" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (code_committed=$has_code tasks_md_diverged=$has_tasks)"
  fi
}

test_frontier_respects_deps() {
  local name="only dependency-free nodes enter the first frontier"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 3 --base-branch main >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" frontier)" = "TASK-001" ] && [ "$(field "$out" action)" = "dispatch" ]; then
    log_pass "$name"
  else
    log_fail "$name (frontier='$(field "$out" frontier)' action='$(field "$out" action)')"
  fi
}

test_inflight_cap_holds() {
  local name="the frontier never exceeds max_in_flight minus what is already in flight"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" action)" = "wait" ] && [ "$(field "$out" inflight)" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (action='$(field "$out" action)' inflight='$(field "$out" inflight)')"
  fi
}

test_claim_writes_homolog_defer_marker() {
  local name="claim writes homolog-mode=defer into the task's workspace scratch"
  local dir marker
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  marker="$(cat "$dir/wt-TASK-001/.context/ship-run/TASK-001/homolog-mode.txt" 2>/dev/null || true)"
  rm -rf "$dir"

  if [ "$marker" = "defer" ]; then
    log_pass "$name"
  else
    log_fail "$name (marker='$marker')"
  fi
}

test_dependents_unlock_after_the_pr_merges() {
  local name="a node whose PR is merged unlocks its dependents"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
    bash "$GRAPH" complete TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" frontier)" = "TASK-002 TASK-003" ]; then
    log_pass "$name"
  else
    log_fail "$name (frontier='$(field "$out" frontier)')"
  fi
}

test_next_is_idempotent() {
  local name="two consecutive next calls with no state change emit the same state"
  local dir a b
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
  )
  a="$(cd "$dir" && bash "$GRAPH" next)"
  b="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$a" = "$b" ]; then
    log_pass "$name"
  else
    log_fail "$name (the two emissions differ)"
  fi
}

test_all_done_emits_done() {
  local name="a graph whose every PR merged emits state=done, not another frontier"
  local dir out
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    mkdir -p ship
    printf -- '- Test Framework: none\n' > ship/config.md
    printf '[{ "id": "TASK-001", "title": "Solo", "deps": [], "files": ["a.ts"] }]\n' > nodes.json
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    git worktree add -q wt -b ship/TASK-001 main
    printf 'x\n' > wt/a.ts
    git -C wt add -A
    git -C wt commit -qm feat
    bash "$GRAPH" claim TASK-001 --worktree wt --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
    bash "$GRAPH" complete TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "done" ] && [ "$(field "$out" action)" = "done" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_dependency_cycle_is_a_deadlock_ask() {
  local name="a dependency cycle emits action=ask, never a silent stall"
  local dir out
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-A", "title": "A", "deps": ["TASK-B"], "files": ["a.ts"] },
  { "id": "TASK-B", "title": "B", "deps": ["TASK-A"], "files": ["b.ts"] }
]
EOF
    # init refuses this shape now, so the cycle is planted after the fact — the
    # one way the mid-run guard can still be reached.
    sed -i.bak 's/TASK-B/TASK-Z/' nodes.json 2>/dev/null || true
    printf '[{ "id": "TASK-A", "title": "A", "deps": [], "files": ["a.ts"] }, { "id": "TASK-B", "title": "B", "deps": ["TASK-A"], "files": ["b.ts"] }]\n' > nodes.json
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    awk -F'\t' -v OFS='\t' '$1 == "TASK-A" { $4 = "TASK-B" } { print }' .context/ship-graph/f/nodes.tsv > .context/ship-graph/f/.n && mv .context/ship-graph/f/.n .context/ship-graph/f/nodes.tsv
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" action)" = "ask" ] && [ "$(field "$out" state)" = "ask" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_failed_root_ends_the_run_with_its_dependents_held() {
  local name="a failed root ends the run with the failed list — its dependents stay held, nothing else is dispatched"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    bash "$GRAPH" fail TASK-001 --reason "develop produced no mutation" >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" state)" = "done" ] && [ "$(field "$out" action)" = "done" ] \
    && printf '%s' "$out" | grep -q '3 held behind a failed dependency'; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_reset_returns_a_failed_node_to_the_frontier() {
  local name="reset puts a failed node back to pending and unfreezes admission"
  local dir out reset_out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    bash "$GRAPH" fail TASK-001 --reason "stopped by the operator" >/dev/null
  )
  reset_out="$(cd "$dir" && bash "$GRAPH" reset TASK-001)"
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if printf '%s' "$reset_out" | grep -q '^reset=TASK-001$' \
    && [ "$(field "$reset_out" remaining_failed)" = "0" ] \
    && [ "$(field "$out" action)" = "dispatch" ] \
    && printf '%s' "$(field "$out" frontier)" | grep -q 'TASK-001'; then
    log_pass "$name"
  else
    log_fail "$name (reset='$reset_out' action='$(field "$out" action)' frontier='$(field "$out" frontier)')"
  fi
}

test_reset_all_clears_every_failed_node_and_keeps_attempts() {
  local name="reset --all resets every failed node, keeps the attempt count, drops the stale workspace"
  local dir out attempts wt
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" abort --reason "operator stopped the run" >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" reset --all)"
  attempts="$(awk -F'\t' '$1 == "TASK-001" { print $9 }' "$dir/.context/ship-graph/f/nodes.tsv")"
  wt="$(awk -F'\t' '$1 == "TASK-001" { print $7 }' "$dir/.context/ship-graph/f/nodes.tsv")"
  local stall_kept=0
  [ -f "$dir/.context/ship-graph/f/progress-TASK-001.txt" ] && stall_kept=1
  rm -rf "$dir"

  if [ "$(field "$out" count)" = "1" ] && [ "$attempts" = "1" ] && [ -z "$wt" ] && [ "$stall_kept" -eq 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (count='$(field "$out" count)' attempts='$attempts' worktree='$wt' stall_kept=$stall_kept)"
  fi
}

test_reset_refuses_a_node_that_is_not_failed() {
  local name="reset refuses a live node — stopping one is abort's job, not reset's"
  local dir rc=0 out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" reset TASK-001 2>&1)" || rc=$?
  local status
  status="$(awk -F'\t' '$1 == "TASK-001" { print $6 }' "$dir/.context/ship-graph/f/nodes.tsv")"
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && [ "$status" = "in_flight" ] && printf '%s' "$out" | grep -q 'abort'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc status='$status' out='$out')"
  fi
}

test_reset_is_all_or_nothing() {
  local name="a typo in one id resets nothing — the graph never lands half a reset"
  local dir rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    bash "$GRAPH" fail TASK-001 --reason stopped >/dev/null
  )
  (cd "$dir" && bash "$GRAPH" reset TASK-001 TASK-999 >/dev/null 2>&1) || rc=$?
  local status
  status="$(awk -F'\t' '$1 == "TASK-001" { print $6 }' "$dir/.context/ship-graph/f/nodes.tsv")"
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && [ "$status" = "failed" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc TASK-001 status='$status')"
  fi
}

test_unknown_dep_is_rejected_at_init() {
  local name="init rejects a dependency on a node that does not exist"
  local dir rc=0
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    printf '[{ "id": "TASK-A", "title": "A", "deps": ["TASK-GHOST"], "files": ["a.ts"] }]\n' > nodes.json
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null 2>&1
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (init accepted a dangling dep edge)"
  fi
}

test_reinit_reports_resume_instead_of_inviting_fresh() {
  local name="a second init on a live graph exits 3 with RESUME, never an error suggesting --fresh"
  local dir out rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main 2>&1)" || rc=$?
  # The live claim must survive the re-init untouched.
  local still
  still="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"status": "in_flight"')"
  rm -rf "$dir"

  if [ "$rc" -eq 3 ] \
    && printf '%s' "$out" | grep -q '^RESUME$' \
    && printf '%s' "$out" | grep -q '^inflight=1$' \
    && ! printf '%s' "$out" | grep -qi 'fresh' \
    && [ "$still" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc still_inflight=$still out='$out')"
  fi
}

test_fresh_still_discards_when_asked() {
  local name="--fresh still discards the graph when it is explicitly requested"
  local dir inflight
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main --fresh >/dev/null
  )
  inflight="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"status": "in_flight"' || true)"
  rm -rf "$dir"

  if [ "$inflight" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name (in_flight nodes after --fresh: $inflight)"
  fi
}

test_counters_survive_a_resumed_graph() {
  local name="iteration counters survive later init attempts (a cap that resets is no cap)"
  local dir out rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    bash "$GRAPH" iter retry --max 2 >/dev/null
    bash "$GRAPH" iter retry --max 2 >/dev/null
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null 2>&1 || true
    out="$(bash "$GRAPH" iter retry --max 2)" || exit 2
    [ "$out" = "count=3" ] || exit 1
  ) || rc=$?
  rm -rf "$dir"

  if [ "$rc" -eq 2 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc — the counter did not survive, or did not exceed the cap)"
  fi
}

test_manual_driver_answers_all_four_verbs() {
  local name="driver-manual answers every verb of the contract without a runtime"
  local dir ok=1 out
  dir="$(mktemp -d)"
  # Captured, not piped: `grep -q` exits on the first match and SIGPIPEs the
  # writer, which `set -o pipefail` would then report as a driver failure.
  out="$(bash "$DRIVER_MANUAL" dispatch TASK-001 "/ship:run TASK-001" --state "$dir")"
  printf '%s\n' "$out" | grep -q '^ok=1$' || ok=0
  out="$(bash "$DRIVER_MANUAL" collect TASK-001 --state "$dir")"
  printf '%s\n' "$out" | grep -q '^worktree=' || ok=0
  out="$(bash "$DRIVER_MANUAL" wait --state "$dir")"
  printf '%s\n' "$out" | grep -q '^timeout=1$' || ok=0
  out="$(bash "$DRIVER_MANUAL" ask "merge?" --state "$dir")"
  printf '%s\n' "$out" | grep -q '^question=merge' || ok=0
  rm -rf "$dir"

  if [ "$ok" -eq 1 ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_nodes_from_tasks_md() {
  local name="nodes --from-tasks converts a local tasks.md into the nodes.json contract"
  local dir out
  dir="$(mktemp -d)"
  cat > "$dir/tasks.md" <<'EOF'
## Milestone 1

### TASK-001 — Schema

## Files
create src/db/schema.ts — tabela

## Deps
none

### TASK-002 — Endpoint

## Files
modify src/api/routes.ts — rota

## Deps
TASK-001
EOF
  out="$(bash "$GRAPH" nodes --from-tasks "$dir/tasks.md")"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '"id": "TASK-002"' \
    && printf '%s' "$out" | grep -q '"deps": \["TASK-001"\]' \
    && printf '%s' "$out" | grep -q '"files": \["src/api/routes.ts"\]' \
    && printf '%s' "$out" | grep -q '"deps": \[\]'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
}

test_json_parser_keeps_empty_fields_aligned() {
  local name="a node with an empty repo does not shift its later columns"
  local dir json
  dir="$(mktemp -d)"
  (
    cd "$dir"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    printf '[{ "id": "TASK-A", "repo": "", "title": "T", "deps": [], "files": ["a.ts"] }]\n' > nodes.json
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
  )
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$json" | grep -q '"title": "T"' \
    && printf '%s' "$json" | grep -q '"files": \["a.ts"\]' \
    && printf '%s' "$json" | grep -q '"status": "pending"'; then
    log_pass "$name"
  else
    log_fail "$name (got: $json)"
  fi
}

test_human_project_name_is_slugified() {
  local name="a human project name is slugified into the graph's identity"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  out="$(cd "$dir" && bash "$GRAPH" init --feature "Checkout V2" --from nodes.json --driver manual --base-branch main)"
  local ok=0
  [ -d "$dir/.context/ship-graph/checkout-v2" ] && ok=1
  rm -rf "$dir"

  if [ "$ok" -eq 1 ] && printf '%s' "$out" | grep -q '^feature=checkout-v2$'; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
}

test_accented_name_yields_a_stable_usable_slug() {
  local name="an accented project name still yields one stable, non-empty slug"
  local dir a b
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (cd "$dir" && bash "$GRAPH" init --feature "Autenticacao V2" --from nodes.json --driver manual --base-branch main >/dev/null)
  a="$(ls "$dir/.context/ship-graph" | grep -v active.txt | head -1)"
  rm -rf "$dir"

  # Same input twice must land on the same graph — accents are folded to dashes,
  # deliberately and identically on every platform (see slugify_feature).
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (cd "$dir" && bash "$GRAPH" init --feature "Autenticação V2" --from nodes.json --driver manual --base-branch main >/dev/null)
  b="$(ls "$dir/.context/ship-graph" | grep -v active.txt | head -1)"
  local again
  (cd "$dir" && rm -rf .context && bash "$GRAPH" init --feature "Autenticação V2" --from nodes.json --driver manual --base-branch main >/dev/null)
  again="$(ls "$dir/.context/ship-graph" | grep -v active.txt | head -1)"
  rm -rf "$dir"

  if [ "$a" = "autenticacao-v2" ] && [ -n "$b" ] && [ "$b" = "$again" ] && [ "${b#-}" = "$b" ]; then
    log_pass "$name"
  else
    log_fail "$name (ascii='$a' accented='$b' repeat='$again')"
  fi
}

test_a_url_is_refused_not_mangled() {
  local name="a project URL is refused, not turned into a directory name"
  local dir rc=0 err
  dir="$(mktemp -d)"
  setup_repo "$dir"
  err="$(cd "$dir" && bash "$GRAPH" init --feature "https://linear.app/acme/project/checkout-v2-9f3a1b" --from nodes.json --driver manual --base-branch main 2>&1)" || rc=$?
  local leaked=0
  [ -d "$dir/.context/ship-graph" ] && [ -n "$(ls -A "$dir/.context/ship-graph" 2>/dev/null)" ] && leaked=1
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && [ "$leaked" -eq 0 ] && printf '%s' "$err" | grep -qi 'not a URL'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc leaked=$leaked err='$err')"
  fi
}

test_slug_is_stable_across_spellings() {
  local name="two spellings of the same project name resolve to the same graph"
  local dir rc=0
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature "Checkout V2" --from nodes.json --driver manual --base-branch main >/dev/null
    # A second init under a different spelling must collide with the live graph,
    # not quietly start a parallel one holding half the nodes.
    bash "$GRAPH" init --feature "checkout   v2" --from nodes.json --driver manual --base-branch main >/dev/null 2>&1
  ) || rc=$?
  local count
  count="$(ls "$dir/.context/ship-graph" 2>/dev/null | grep -vc active.txt || true)"
  rm -rf "$dir"

  if [ "$rc" -ne 0 ] && [ "$count" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc, graph dirs=$count)"
  fi
}

test_isolation_guard_passes_on_the_real_tree() {
  local name="the driver-isolation guard passes against the committed tree"
  if bash "$REPO_ROOT/scripts/check-graph-driver-isolation.sh" >/dev/null 2>&1; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_isolation_guard_catches_a_runtime_call_in_graph_sh() {
  local name="the guard fails when a runtime call is smuggled into graph.sh"
  local root rc=0
  root="$(mktemp -d)"
  mkdir -p "$root/src/hooks" "$root/src/skills/graph" "$root/scripts"
  cp "$REPO_ROOT/src/hooks/graph.sh" "$root/src/hooks/graph.sh"
  cp "$REPO_ROOT"/src/hooks/driver-*.sh "$root/src/hooks/"
  cp "$REPO_ROOT/src/skills/graph/SKILL.md" "$root/src/skills/graph/SKILL.md"
  cp "$REPO_ROOT/scripts/check-graph-driver-isolation.sh" "$root/scripts/"
  printf 'orca worktree show --worktree "$id" --json\n' >> "$root/src/hooks/graph.sh"

  GRAPH_ISOLATION_ROOT="$root" bash "$root/scripts/check-graph-driver-isolation.sh" >/dev/null 2>&1 || rc=$?
  rm -rf "$root"

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (the guard accepted a runtime call in graph.sh)"
  fi
}

test_isolation_guard_catches_a_driver_missing_a_verb() {
  local name="the guard fails when a driver stops implementing one of the contract verbs"
  local root rc=0
  root="$(mktemp -d)"
  mkdir -p "$root/src/hooks" "$root/src/skills/graph" "$root/scripts"
  cp "$REPO_ROOT/src/hooks/graph.sh" "$root/src/hooks/graph.sh"
  cp "$REPO_ROOT/src/skills/graph/SKILL.md" "$root/src/skills/graph/SKILL.md"
  cp "$REPO_ROOT/scripts/check-graph-driver-isolation.sh" "$root/scripts/"
  printf '#!/usr/bin/env bash\nverb_dispatch() { :; }\nverb_collect() { :; }\nverb_wait() { :; }\n' \
    > "$root/src/hooks/driver-broken.sh"

  GRAPH_ISOLATION_ROOT="$root" bash "$root/scripts/check-graph-driver-isolation.sh" >/dev/null 2>&1 || rc=$?
  rm -rf "$root"

  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (the guard accepted a driver with no 'ask' verb)"
  fi
}

test_frontier_respects_deps
test_abort_stops_workers_and_keeps_workspaces
test_abort_is_a_noop_with_nothing_in_flight
test_every_driver_answers_stop
test_guard_catches_a_driver_missing_stop
test_poll_writes_progress_to_the_log
test_seal_keeps_shared_tasks_md_out_of_node_commits
test_init_seals_the_spec_onto_the_base
test_init_seal_is_idempotent_and_scoped
test_tasks_md_parser_ignores_rules_and_prose
test_failed_init_leaves_no_debris
test_corrected_init_after_a_failure_is_not_refused_as_resume
test_poll_lands_on_the_completion_artifact_not_a_handshake
# --- what a 17-node live run actually did ------------------------------------
#
# Two healthy nodes were killed 45 seconds into a develop phase, their finished
# work discarded, re-dispatched into fresh workspaces and killed again — and the
# ten nodes downstream of them never ran. Both halves of the cause are pinned
# here: the stall cap counted POLLS (a measure of the coordinator's turn
# latency, not the worker's silence), and progress was dispatch-log.md's row
# count alone (which does not move during the phases that take the longest).

test_a_fast_poll_loop_cannot_fail_a_working_node() {
  local name="a quiet node is not failed until the quiet SECONDS run out, however fast the coordinator polls"
  local dir out status resumed i
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    # Twenty polls back to back — far past --stall-max — inside a window that
    # has not elapsed. This is the live cadence: 13-16s apart against a
    # five-minute wait that was returning immediately.
    for i in $(seq 20); do bash "$GRAPH" poll > poll.txt; done
  )
  out="$(cat "$dir/poll.txt")"
  status="$(cd "$dir" && bash "$GRAPH" status | awk '$1 == "TASK-001" { print $2 }')"
  resumed="$(grep -c 'worker resumed once' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null | head -1 || true)"
  rm -rf "$dir"

  if [ "$status" = "in_flight" ] && [ "$resumed" = "0" ] \
    && printf '%s' "$out" | grep -q '^quiet=TASK-001$'; then
    log_pass "$name"
  else
    log_fail "$name (status=$status resumed=$resumed out='$out')"
  fi
}

test_the_quiet_log_line_names_the_seconds() {
  local name="the quiet log line reports the seconds that decide, not only the poll count"
  local dir line
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll >/dev/null; bash "$GRAPH" poll >/dev/null
  )
  line="$(grep 'quiet (' "$dir/.context/ship-graph/f/graph-log.md" | tail -1)"
  rm -rf "$dir"
  # Whoever is watching graph-log.md has to be able to tell "45 seconds in" from
  # "fifteen minutes in" — the old line said "2/3 polls" for both.
  if printf '%s' "$line" | grep -qE 's of [0-9]+s with nothing written'; then
    log_pass "$name"
  else
    log_fail "$name (line='$line')"
  fi
}

test_work_in_the_tree_counts_as_progress() {
  local name="a worker writing source files is progress — develop dispatches one row and then writes for minutes"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    bash "$GRAPH" poll --stall-after 0 >/dev/null
    # No new dispatch row — this is develop implementing, which is exactly the
    # stretch the row count is blind to.
    printf 'export const y = 2\n' > wt-TASK-001/src/db/other.ts
    bash "$GRAPH" poll --stall-after 0 > poll.txt
  )
  out="$(cat "$dir/poll.txt")"
  rm -rf "$dir"
  if printf '%s' "$out" | grep -q '^working=TASK-001$'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_a_resume_buys_a_whole_new_window() {
  local name="a resumed node gets a fresh quiet window, not the three polls left over from the old one"
  local dir status i
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    # Run the clock out once so the node is resumed...
    for i in 1 2 3 4; do bash "$GRAPH" poll --stall-after 0 >/dev/null; done
    # ...then poll under a real window. The node was just nudged; failing it now
    # on the leftover clock is the loop this exists to break.
    for i in 1 2 3 4 5; do bash "$GRAPH" poll >/dev/null; done
  )
  status="$(cd "$dir" && bash "$GRAPH" status | awk '$1 == "TASK-001" { print $2 }')"
  rm -rf "$dir"
  if [ "$status" = "in_flight" ]; then
    log_pass "$name"
  else
    log_fail "$name (status=$status)"
  fi
}

test_stall_after_is_a_live_knob() {
  local name="set --stall-after changes a live graph's quiet window without touching nodes or counters"
  local dir out meta
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" set --stall-after 1800)"
  meta="$(grep '^stall_after' "$dir/.context/ship-graph/f/meta.tsv" | cut -f2)"
  local rc=0
  (cd "$dir" && bash "$GRAPH" set --stall-after 30 >/dev/null 2>&1) || rc=$?
  rm -rf "$dir"
  # Below a minute is not a window, it is the bug with a different number.
  if printf '%s' "$out" | grep -q '^stall_after=1800$' && [ "$meta" = "1800" ] && [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' meta=$meta rc=$rc)"
  fi
}

test_wait_names_the_artifacts_it_is_waiting_for() {
  local name="the wait instruction names each in-flight node's completion, failure and question files"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" next > next.txt
  )
  out="$(cat "$dir/next.txt")"
  rm -rf "$dir"
  # The graph is the one that knows what "done" looks like; the driver only
  # knows how to block. Without these the window is spent listening to a
  # channel the worker writes to when it gets round to it — measured 3m37s
  # after the artifact was already on disk.
  if printf '%s' "$out" | grep -q -- '--until-file .*/homolog-approved.txt' \
    && printf '%s' "$out" | grep -q -- '--until-file .*/node-failed.txt' \
    && printf '%s' "$out" | grep -q -- '--until-file .*/ask.md'; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_claim_marks_the_workspace_as_having_a_coordinator
test_a_nodes_question_reaches_the_coordinator
test_answer_refuses_a_node_with_no_pending_question
test_poll_seals_uncommitted_work_into_the_branch
test_poll_reports_progress_without_landing
test_stalled_node_is_resumed_retried_then_reported
test_never_started_node_is_redispatched_within_the_cap
test_a_fast_poll_loop_cannot_fail_a_working_node
test_the_quiet_log_line_names_the_seconds
test_work_in_the_tree_counts_as_progress
test_a_resume_buys_a_whole_new_window
test_stall_after_is_a_live_knob
test_wait_names_the_artifacts_it_is_waiting_for
test_a_failure_by_decision_is_never_retried
test_init_refuses_a_dependency_cycle
test_progress_resets_the_stall_counter
test_inflight_cap_holds
test_claim_writes_homolog_defer_marker
test_dependents_unlock_after_the_pr_merges
test_next_is_idempotent
test_all_done_emits_done
test_dependency_cycle_is_a_deadlock_ask
test_failed_root_ends_the_run_with_its_dependents_held
test_reset_returns_a_failed_node_to_the_frontier
test_reset_all_clears_every_failed_node_and_keeps_attempts
test_reset_refuses_a_node_that_is_not_failed
test_reset_is_all_or_nothing
test_unknown_dep_is_rejected_at_init
test_answer_wakes_the_worker_through_the_driver
test_batch_admission_holds_a_freed_slot
test_a_failed_node_does_not_freeze_the_run
test_a_run_ending_with_failures_reports_them_once
test_poll_fails_a_node_from_its_own_verdict
test_next_refreshes_stale_conflict_edges_itself
test_reinit_reports_resume_instead_of_inviting_fresh
test_fresh_still_discards_when_asked
test_counters_survive_a_resumed_graph
test_manual_driver_answers_all_four_verbs
test_nodes_from_tasks_md
test_json_parser_keeps_empty_fields_aligned
test_human_project_name_is_slugified
test_accented_name_yields_a_stable_usable_slug
test_a_url_is_refused_not_mangled
test_slug_is_stable_across_spellings
test_isolation_guard_passes_on_the_real_tree
test_isolation_guard_catches_a_runtime_call_in_graph_sh
test_isolation_guard_catches_a_driver_missing_a_verb

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
