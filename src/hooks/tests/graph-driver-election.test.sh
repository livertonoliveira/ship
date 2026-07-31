#!/usr/bin/env bash

set -euo pipefail

# Regressions from a real 23-node run that was supposed to open one app workspace
# per issue and opened none.
#
# The first init hit a runtime whose orchestration API had moved, so the graph
# fell back to the driver that spawns nothing. That fallback was written to meta
# once — and every batch for the next eight hours, across sessions, long after
# the runtime was working again, kept using it, because nothing ever revisited
# the election and nothing in any status said which driver was in force. The user
# only found out by noticing the app was empty.
#
# So: an election made by probe is revisited whenever it is safe to; an election
# made by hand is not; and the driver in force is on every `next`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="$SCRIPT_DIR/.."

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# Each sandbox gets its OWN copy of the hooks, because these tests work by adding
# and removing driver files: graph.sh globs driver-*.sh out of its own directory,
# so a fake driver dropped into the real tree would leak into every later test.
new_sandbox() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/hooks" "$root/repo"
  cp "$HOOKS_SRC"/*.sh "$root/hooks/"
  # Hermetic election: on a developer machine a real runtime driver probes ready
  # and outranks everything, so the sandbox would elect whatever happened to be
  # running and these tests would pass or fail by the state of the desktop. Drop
  # any copied driver that outranks the plain-worktree fallback and let the fakes
  # below play that part. Selected by what a driver CLAIMS, never by its name.
  local d out prio
  for d in "$root/hooks"/driver-*.sh; do
    out="$(bash "$d" probe 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '^ready=1' || continue
    prio="$(printf '%s' "$out" | sed -n 's/^priority=//p' | head -1)"
    case "$prio" in ''|*[!0-9]*) continue ;; esac
    [ "$prio" -lt 50 ] && rm -f "$d"
  done
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
    printf -- '- Test Framework: none\n' > ship/config.md
    cat > nodes.json <<'EOF'
[ { "id": "N1", "title": "One", "deps": [], "files": ["src/a.ts"] },
  { "id": "N2", "title": "Two", "deps": [], "files": ["src/b.ts"] } ]
EOF
  )
  printf '%s' "$root"
}

# A driver that outranks driver-local (priority 50) whenever its marker file is
# present, and reports itself absent when it is not — a runtime going up and down
# under a live graph, which is the whole situation being tested.
install_fake_driver() {
  local root="$1" name="$2" prio="$3"
  cat > "$root/hooks/driver-$name.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "probe" ]; then
  if [ -f "$root/$name-up" ]; then
    printf 'ready=1\n'
    printf 'priority=$prio\n'
    printf 'workspaces=one runtime-managed workspace per node\n'
  else
    printf 'ready=0\n'
    printf 'reason=down\n'
  fi
  exit 0
fi
printf 'ok=1\n'
EOF
}

meta_of() { sed -n "s/^$2\t//p" "$1/.context/ship-graph/f/meta.tsv"; }

# --- election is recorded, not just made -------------------------------------

test_probe_election_is_recorded_as_probe() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --mode local >/dev/null )

  if [ "$(meta_of "$repo" driver_chosen_by)" = "probe" ]; then
    log_pass "an election made by probe is recorded as such"
  else
    log_fail "an election made by probe is recorded as such (got '$(meta_of "$repo" driver_chosen_by)')"
  fi
  rm -rf "$root"
}

test_explicit_driver_is_recorded_as_explicit() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --driver local --mode local >/dev/null )

  if [ "$(meta_of "$repo" driver_chosen_by)" = "explicit" ]; then
    log_pass "a driver named by hand is recorded as explicit"
  else
    log_fail "a driver named by hand is recorded as explicit (got '$(meta_of "$repo" driver_chosen_by)')"
  fi
  rm -rf "$root"
}

test_init_records_what_the_driver_produces() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --driver local --mode local >/dev/null )

  # driver-local's own words. graph.sh must echo the label, never author one.
  if meta_of "$repo" driver_workspaces | grep -q "NOT visible"; then
    log_pass "init records what the elected driver actually produces"
  else
    log_fail "init records what the elected driver actually produces (got '$(meta_of "$repo" driver_workspaces)')"
  fi
  rm -rf "$root"
}

# --- the root cause: a fallback that never healed ----------------------------

test_next_reelects_when_a_better_driver_comes_up() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  install_fake_driver "$root" "runtime" 10
  # Runtime down at init: the graph correctly falls back to local.
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --mode local >/dev/null )
  [ "$(meta_of "$repo" driver)" = "local" ] || { log_fail "precondition: init falls back to local while the runtime is down"; rm -rf "$root"; return; }

  touch "$root/runtime-up"
  ( cd "$repo" && bash "$root/hooks/graph.sh" next >/dev/null 2>&1 ) || true

  if [ "$(meta_of "$repo" driver)" = "runtime" ]; then
    log_pass "next re-elects the runtime driver once it is reachable again"
  else
    log_fail "next re-elects the runtime driver once it is reachable again (still '$(meta_of "$repo" driver)')"
  fi
  rm -rf "$root"
}

test_reelection_updates_the_workspace_label() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  install_fake_driver "$root" "runtime" 10
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --mode local >/dev/null )
  touch "$root/runtime-up"
  ( cd "$repo" && bash "$root/hooks/graph.sh" next >/dev/null 2>&1 ) || true

  if meta_of "$repo" driver_workspaces | grep -q "runtime-managed"; then
    log_pass "re-election refreshes the recorded workspace label"
  else
    log_fail "re-election refreshes the recorded workspace label (got '$(meta_of "$repo" driver_workspaces)')"
  fi
  rm -rf "$root"
}

test_legacy_graph_without_the_field_still_heals() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  install_fake_driver "$root" "runtime" 10
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --mode local >/dev/null )
  # A graph written by a Ship that predates the field — exactly the state the
  # real failing run was left in.
  grep -v '^driver_chosen_by' "$repo/.context/ship-graph/f/meta.tsv" > "$repo/.context/ship-graph/f/meta.new"
  mv "$repo/.context/ship-graph/f/meta.new" "$repo/.context/ship-graph/f/meta.tsv"

  touch "$root/runtime-up"
  ( cd "$repo" && bash "$root/hooks/graph.sh" next >/dev/null 2>&1 ) || true

  if [ "$(meta_of "$repo" driver)" = "runtime" ]; then
    log_pass "a graph predating the field is treated as probe-elected and heals"
  else
    log_fail "a graph predating the field is treated as probe-elected and heals (still '$(meta_of "$repo" driver)')"
  fi
  rm -rf "$root"
}

# --- and the two things re-election must never do ----------------------------

test_explicit_driver_is_never_reelected() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  install_fake_driver "$root" "runtime" 10
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --driver local --mode local >/dev/null )
  touch "$root/runtime-up"
  ( cd "$repo" && bash "$root/hooks/graph.sh" next >/dev/null 2>&1 ) || true

  if [ "$(meta_of "$repo" driver)" = "local" ]; then
    log_pass "a pinned driver survives a better one coming up"
  else
    log_fail "a pinned driver survives a better one coming up (became '$(meta_of "$repo" driver)')"
  fi
  rm -rf "$root"
}

test_no_reelection_while_a_node_is_held() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  install_fake_driver "$root" "runtime" 10
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --mode local >/dev/null )
  mkdir -p "$root/wt"
  ( cd "$repo" && bash "$root/hooks/graph.sh" claim N1 --worktree "$root/wt" --branch ship/N1 >/dev/null )
  grep -q 'in_flight' "$repo/.context/ship-graph/f/nodes.tsv" || {
    log_fail "precondition: claim puts N1 in flight"; rm -rf "$root"; return
  }

  touch "$root/runtime-up"
  ( cd "$repo" && bash "$root/hooks/graph.sh" next >/dev/null 2>&1 ) || true

  # An in-flight node can only be collected, waited on and stopped through the
  # driver that dispatched it. Swapping underneath it orphans a live worker.
  if [ "$(meta_of "$repo" driver)" = "local" ]; then
    log_pass "re-election waits while a node is still held by the current driver"
  else
    log_fail "re-election waits while a node is still held by the current driver (became '$(meta_of "$repo" driver)')"
  fi
  rm -rf "$root"
}

test_set_driver_pins_against_later_reelection() {
  local root repo
  root="$(new_sandbox)"; repo="$root/repo"
  install_fake_driver "$root" "runtime" 10
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --mode local >/dev/null )
  ( cd "$repo" && bash "$root/hooks/graph.sh" set --feature f --driver local >/dev/null )
  touch "$root/runtime-up"
  ( cd "$repo" && bash "$root/hooks/graph.sh" next >/dev/null 2>&1 ) || true

  if [ "$(meta_of "$repo" driver)" = "local" ]; then
    log_pass "set --driver pins the choice against later re-election"
  else
    log_fail "set --driver pins the choice against later re-election (became '$(meta_of "$repo" driver)')"
  fi
  rm -rf "$root"
}

# --- and it has to be visible ------------------------------------------------

test_next_reports_the_driver_and_its_workspaces() {
  local root repo out
  root="$(new_sandbox)"; repo="$root/repo"
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --driver local --mode local >/dev/null )
  out="$( cd "$repo" && bash "$root/hooks/graph.sh" next 2>/dev/null || true )"

  if printf '%s' "$out" | grep -q '^driver=local$' && printf '%s' "$out" | grep -q '^workspaces=.*NOT visible'; then
    log_pass "next names the driver in force and what it produces"
  else
    log_fail "next names the driver in force and what it produces"
  fi
  rm -rf "$root"
}

test_status_reports_the_workspaces() {
  local root repo out
  root="$(new_sandbox)"; repo="$root/repo"
  ( cd "$repo" && bash "$root/hooks/graph.sh" init --feature f --from nodes.json --driver local --mode local >/dev/null )
  out="$( cd "$repo" && bash "$root/hooks/graph.sh" status 2>/dev/null || true )"

  if printf '%s' "$out" | grep -q '^workspaces: '; then
    log_pass "status names what the driver produces"
  else
    log_fail "status names what the driver produces"
  fi
  rm -rf "$root"
}

# --- every shipped driver has to answer the question -------------------------

test_every_driver_declares_its_workspaces() {
  local f name out missing=""
  for f in "$HOOKS_SRC"/driver-*.sh; do
    name="$(basename "$f" .sh)"
    out="$(bash "$f" probe 2>/dev/null || true)"
    printf '%s' "$out" | grep -q '^ready=1' || continue
    printf '%s' "$out" | grep -q '^workspaces=' || missing="$missing $name"
  done
  if [ -z "$missing" ]; then
    log_pass "every ready driver declares what its workspaces are"
  else
    log_fail "every ready driver declares what its workspaces are (missing:$missing)"
  fi
}

test_probe_election_is_recorded_as_probe
test_explicit_driver_is_recorded_as_explicit
test_init_records_what_the_driver_produces
test_next_reelects_when_a_better_driver_comes_up
test_reelection_updates_the_workspace_label
test_legacy_graph_without_the_field_still_heals
test_explicit_driver_is_never_reelected
test_no_reelection_while_a_node_is_held
test_set_driver_pins_against_later_reelection
test_next_reports_the_driver_and_its_workspaces
test_status_reports_the_workspaces
test_every_driver_declares_its_workspaces

echo ""
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
