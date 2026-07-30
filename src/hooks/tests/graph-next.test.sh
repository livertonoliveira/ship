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
# merge and a real footprint to read.
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
  out="$(cd "$dir" && bash "$GRAPH" poll)"
  local status
  status="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"status": "landed"')"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^landed=TASK-001$' && [ "$status" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (out='$out' landed_nodes=$status)"
  fi
}

test_poll_seals_uncommitted_work_into_the_branch() {
  local name="landing commits the workspace — develop never commits, so the merge would be empty"
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
    bash "$GRAPH" poll >/dev/null
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
  out="$(cd "$dir" && bash "$GRAPH" poll)"
  rm -rf "$dir"

  if printf '%s' "$out" | grep -q '^working=TASK-001$' && ! printf '%s' "$out" | grep -q '^landed='; then
    log_pass "$name"
  else
    log_fail "$name (out='$out')"
  fi
}

test_stalled_node_surfaces_instead_of_waiting_forever() {
  local name="a node with no phase progress across 3 polls surfaces as ask, never an endless wait"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    # The exact shape of the Orca failure: workspace up, prompt never submitted,
    # so the pipeline never dispatches a phase and nothing ever changes.
    bash "$GRAPH" poll >/dev/null
    bash "$GRAPH" poll >/dev/null
    bash "$GRAPH" poll >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" action)" = "ask" ] && printf '%s' "$out" | grep -q 'TASK-001'; then
    log_pass "$name"
  else
    log_fail "$name (action='$(field "$out" action)')"
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
    bash "$GRAPH" poll >/dev/null
    bash "$GRAPH" poll >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll >/dev/null
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
  local name="poll records progress and stalls in graph-log.md, not just on stdout"
  local dir working stalled
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    printf '| dev | Skill | ship:develop | sonnet | t |\n' > "wt-TASK-001/.context/ship-run/TASK-001/dispatch-log.md"
    bash "$GRAPH" poll >/dev/null
    bash "$GRAPH" poll >/dev/null
    bash "$GRAPH" poll >/dev/null
    bash "$GRAPH" poll >/dev/null
  )
  working="$(grep -c 'working —' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null || echo 0)"
  stalled="$(grep -c 'STALLED' "$dir/.context/ship-graph/f/graph-log.md" 2>/dev/null || echo 0)"
  rm -rf "$dir"

  # Without this the only progress signal lives inside the orchestrator's turn,
  # and from outside a working run is indistinguishable from a stuck one.
  if [ "$working" -ge 1 ] && [ "$stalled" -ge 1 ]; then
    log_pass "$name"
  else
    log_fail "$name (working=$working stalled=$stalled)"
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
    bash "$GRAPH" poll >/dev/null
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

test_dependents_unlock_after_done() {
  local name="completing a node unlocks its dependents"
  local dir out
  dir="$(mktemp -d)"
  setup_repo "$dir"
  (
    cd "$dir"
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    make_workspace "$dir" TASK-001 src/db/schema.ts
    bash "$GRAPH" claim TASK-001 --worktree "wt-TASK-001" --branch ship/TASK-001 >/dev/null
    bash "$GRAPH" land TASK-001 >/dev/null
    bash "$GRAPH" merge TASK-001 >/dev/null
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
  local name="a fully integrated graph emits state=done, not another frontier"
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
    bash "$GRAPH" merge TASK-001 >/dev/null
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
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" action)" = "ask" ] && [ "$(field "$out" state)" = "ask" ]; then
    log_pass "$name"
  else
    log_fail "$name (state='$(field "$out" state)' action='$(field "$out" action)')"
  fi
}

test_failed_node_freezes_admission() {
  local name="a failed node freezes admission instead of dispatching the rest"
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

  if [ "$(field "$out" action)" = "ask" ]; then
    log_pass "$name"
  else
    log_fail "$name (action='$(field "$out" action)')"
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
    bash "$GRAPH" iter merge-fix --max 2 >/dev/null
    bash "$GRAPH" iter merge-fix --max 2 >/dev/null
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null 2>&1 || true
    out="$(bash "$GRAPH" iter merge-fix --max 2)" || exit 2
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
  local name="driver-manual answers all four verbs without a runtime"
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
  local name="the guard fails when a driver stops implementing one of the four verbs"
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
test_poll_seals_uncommitted_work_into_the_branch
test_poll_reports_progress_without_landing
test_stalled_node_surfaces_instead_of_waiting_forever
test_progress_resets_the_stall_counter
test_inflight_cap_holds
test_claim_writes_homolog_defer_marker
test_dependents_unlock_after_done
test_next_is_idempotent
test_all_done_emits_done
test_dependency_cycle_is_a_deadlock_ask
test_failed_node_freezes_admission
test_reset_returns_a_failed_node_to_the_frontier
test_reset_all_clears_every_failed_node_and_keeps_attempts
test_reset_refuses_a_node_that_is_not_failed
test_reset_is_all_or_nothing
test_unknown_dep_is_rejected_at_init
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
