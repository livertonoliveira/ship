#!/usr/bin/env bash

# The conflict edge is what replaces "never run two tasks in parallel". It has
# to hold in three situations: two ready nodes that would collide, a node whose
# real footprint turned out wider than the spec declared, and a repeat run that
# must produce the same winner every time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"

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

field() {
  printf '%s\n' "$1" | grep "^$2=" | head -1 | sed "s/^$2=//"
}

new_repo() {
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
    printf -- '- Test Framework: none\n' > ship/config.md
  )
}

test_overlapping_ready_nodes_do_not_share_a_frontier() {
  local name="two ready nodes with an overlapping footprint never enter the same frontier"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "Rota", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-004", "title": "Rota extra", "deps": [], "files": ["src/api/routes.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 4 --base-branch main >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" frontier)" = "TASK-002" ]; then
    log_pass "$name"
  else
    log_fail "$name (frontier='$(field "$out" frontier)', expected only TASK-002)"
  fi
}

test_directory_prefix_counts_as_overlap() {
  local name="a declared directory collides with a file inside it"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "Rota", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-004", "title": "Refactor da pasta", "deps": [], "files": ["src/api"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 4 --base-branch main >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" frontier)" = "TASK-002" ]; then
    log_pass "$name"
  else
    log_fail "$name (frontier='$(field "$out" frontier)')"
  fi
}

test_sibling_directory_is_not_an_overlap() {
  local name="src/apiv2 is not inside src/api — a prefix match must respect the / boundary"
  local dir out
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "A", "deps": [], "files": ["src/api"] },
  { "id": "TASK-004", "title": "B", "deps": [], "files": ["src/apiv2/routes.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 4 --base-branch main >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$(field "$out" frontier)" = "TASK-002 TASK-004" ]; then
    log_pass "$name"
  else
    log_fail "$name (frontier='$(field "$out" frontier)')"
  fi
}

test_lowest_id_wins_the_slot_deterministically() {
  local name="the tie-break is by lowest id and repeats identically across runs"
  local dir first second
  local i
  for i in 1 2; do
    dir="$(mktemp -d)"
    new_repo "$dir"
    (
      cd "$dir"
      cat > nodes.json <<'EOF'
[
  { "id": "TASK-009", "title": "Nono", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-003", "title": "Terceiro", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-007", "title": "Sétimo", "deps": [], "files": ["src/api/routes.ts"] }
]
EOF
      bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 4 --base-branch main >/dev/null
    )
    if [ "$i" = "1" ]; then
      first="$(cd "$dir" && bash "$GRAPH" next)"
    else
      second="$(cd "$dir" && bash "$GRAPH" next)"
    fi
    rm -rf "$dir"
  done

  if [ "$(field "$first" frontier)" = "TASK-003" ] && [ "$first" = "$second" ]; then
    log_pass "$name"
  else
    log_fail "$name (frontier='$(field "$first" frontier)', stable=$([ "$first" = "$second" ] && echo yes || echo no))"
  fi
}

test_loser_is_blocked_by_conflict_not_failed() {
  local name="the node that lost the slot is recorded as blocked_by_conflict, not failed"
  local dir json
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "A", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-004", "title": "B", "deps": [], "files": ["src/api/routes.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 4 --base-branch main >/dev/null
    bash "$GRAPH" next >/dev/null
  )
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$json" | grep -q '"blocked_by_conflict": "TASK-002"' \
    && ! printf '%s' "$json" | grep -q '"status": "failed"'; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_real_footprint_overrides_the_declared_one() {
  local name="an in-flight node's real footprint overrides what the spec declared"
  local dir json
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "Declarou pouco", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-004", "title": "Vizinha", "deps": [], "files": ["src/web/page.tsx"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    git worktree add -q wt-002 -b ship/TASK-002 main
    # develop touched more than the spec predicted: it also wrote the neighbour's file.
    mkdir -p wt-002/src/api wt-002/src/web
    printf 'x\n' > wt-002/src/api/routes.ts
    printf 'x\n' > wt-002/src/web/page.tsx
    git -C wt-002 add -A
    git -C wt-002 commit -qm "feat: more than declared"
    bash "$GRAPH" claim TASK-002 --worktree wt-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" conflicts >/dev/null
  )
  json="$(cd "$dir" && bash "$GRAPH" status --json)"
  rm -rf "$dir"

  if printf '%s' "$json" | grep -q '"src/web/page.tsx"' \
    && printf '%s' "$json" | grep -q '"blocked_by_conflict": "TASK-004"'; then
    log_fail "$name (the wrong node got blocked)"
  elif printf '%s' "$json" | grep -q '"blocked_by_conflict": "TASK-002"'; then
    log_pass "$name"
  else
    log_fail "$name (TASK-004 was not held back by the refreshed footprint)"
  fi
}

test_conflicts_reports_how_many_it_refreshed() {
  local name="conflicts reports the count of footprints it refreshed and nodes it blocked"
  local dir out still_blocked
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "A", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-004", "title": "B", "deps": [], "files": ["src/api/routes.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 1 --base-branch main >/dev/null
    git worktree add -q wt-002 -b ship/TASK-002 main
    mkdir -p wt-002/src/api
    printf 'x\n' > wt-002/src/api/routes.ts
    git -C wt-002 add -A
    git -C wt-002 commit -qm feat
    bash "$GRAPH" claim TASK-002 --worktree wt-002 --branch ship/TASK-002 >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" conflicts)"
  rm -rf "$dir"

  if [ "$(field "$out" refreshed)" = "1" ] && [ "$(field "$out" blocked)" = "1" ]; then
    log_pass "$name"
  else
    log_fail "$name (got refreshed='$(field "$out" refreshed)' blocked='$(field "$out" blocked)')"
  fi
}

test_conflict_clears_once_the_holder_is_merged() {
  local name="a conflict edge holds while the holder's PR is open and clears once it merges"
  local dir out still_blocked
  dir="$(mktemp -d)"
  new_repo "$dir"
  (
    cd "$dir"
    cat > nodes.json <<'EOF'
[
  { "id": "TASK-002", "title": "A", "deps": [], "files": ["src/api/routes.ts"] },
  { "id": "TASK-004", "title": "B", "deps": [], "files": ["src/api/routes.ts"] }
]
EOF
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --max-in-flight 2 --base-branch main >/dev/null
    git worktree add -q wt-002 -b ship/TASK-002 main
    mkdir -p wt-002/src/api
    printf 'x\n' > wt-002/src/api/routes.ts
    git -C wt-002 add -A
    git -C wt-002 commit -qm feat
    bash "$GRAPH" claim TASK-002 --worktree wt-002 --branch ship/TASK-002 >/dev/null
    bash "$GRAPH" conflicts >/dev/null
    bash "$GRAPH" land TASK-002 >/dev/null
    bash "$GRAPH" conflicts >/dev/null
  )
  # Landed is not merged: the PR is still open, so its files are not on the base
  # and the neighbour must stay blocked.
  still_blocked="$(cd "$dir" && bash "$GRAPH" status --json | grep -c '"blocked_by_conflict": "TASK-002"' || true)"
  (
    cd "$dir"
    bash "$GRAPH" complete TASK-002 >/dev/null
    bash "$GRAPH" conflicts >/dev/null
  )
  out="$(cd "$dir" && bash "$GRAPH" next)"
  rm -rf "$dir"

  if [ "$still_blocked" = "1" ] && [ "$(field "$out" frontier)" = "TASK-004" ]; then
    log_pass "$name"
  else
    log_fail "$name (blocked_while_open=$still_blocked frontier='$(field "$out" frontier)')"
  fi
}

test_overlapping_ready_nodes_do_not_share_a_frontier
test_directory_prefix_counts_as_overlap
test_sibling_directory_is_not_an_overlap
test_lowest_id_wins_the_slot_deterministically
test_loser_is_blocked_by_conflict_not_failed
test_real_footprint_overrides_the_declared_one
test_conflicts_reports_how_many_it_refreshed
test_conflict_clears_once_the_holder_is_merged

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
