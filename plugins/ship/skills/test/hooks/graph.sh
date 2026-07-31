#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# graph.sh — the work graph. Decides only WHAT MAY RUN NOW; each node is the
# pipeline that already exists (pipeline.sh next) running in its own workspace.
#
# Two edges gate admission:
#   dependency — declared in the spec's `## Deps`; immutable during a run.
#   conflict   — files(A) ∩ files(B) ≠ ∅; the declared `## Files` footprint until
#                a node is in flight, then the REAL footprint of its workspace.
#
# The graph never merges anything and never runs a test suite. Each node syncs
# its own branch against the base and opens its own PR from inside its workspace,
# with the full context of the change it just implemented; the forge is the only
# place a merge happens. What this script observes is the real PR state, and a
# dependent is admitted only once its dependency's PR is MERGED there.
#
# This script never names a workspace runtime. Everything runtime-specific goes
# through driver-<name>.sh's five verbs (dispatch/collect/wait/ask/stop), so swapping
# runtimes is swapping a file. scripts/check-graph-driver-isolation.sh enforces it.
# ---------------------------------------------------------------------------

usage() {
  echo "usage: graph.sh <subcommand> [args...]" >&2
  echo "  init      --feature <f> --from <nodes.json> [--driver <d>] [--max-in-flight N]" >&2
  echo "            [--base-branch <ref>] [--mode linear|local] [--repo <id>] [--node-pr on|off] [--fresh]" >&2
  echo "  set       [--feature <f>] [--driver <d>] [--max-in-flight N] [--node-pr on|off]" >&2
  echo "  next      [--feature <f>]" >&2
  echo "  claim     <task> --worktree <path> --branch <ref> [--feature <f>]" >&2
  echo "  land      <task> [--feature <f>]" >&2
  echo "  poll      [--feature <f>] [--stall-max N]" >&2
  echo "  complete  <task> [--feature <f>]" >&2
  echo "  fail      <task> --reason <r> [--feature <f>]" >&2
  echo "  answer    <task> <answer> [--feature <f>]" >&2
  echo "  reset     <task>... | --all [--feature <f>]" >&2
  echo "  abort     [--feature <f>] [--reason <r>]" >&2
  echo "  conflicts [--feature <f>]" >&2
  echo "  status    [--feature <f>] [--json]" >&2
  echo "  iter      <counter-name> [--max N] [--feature <f>]" >&2
  echo "  nodes     --from-tasks <tasks.md>" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
GRAPH_ROOT=".context/ship-graph"
ACTIVE_POINTER="$GRAPH_ROOT/active.txt"

# Column order of nodes.tsv — the awk field numbers below refer to it:
#   1 id  2 repo  3 title  4 deps  5 files
#   6 status  7 worktree  8 branch  9 attempts  10 blocked_by_conflict
# status: pending → ready → in_flight → landed → merged
#         landed = the node's pipeline finished and its PR is open
#         merged = that PR is merged on the forge — the only signal that
#                  releases dependents
#         failed halts admission; `reset` returns it to pending
#
# Per-node PR state lives in pr-status.tsv (id, number, state, url) rather than
# an eleventh column: every awk above indexes nodes.tsv by field number, and the
# PR is metadata about a node, not an input to scheduling beyond its state.

die() { echo "graph.sh: $*" >&2; exit 1; }

valid_id() {
  case "$1" in
    ''|*[!a-zA-Z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- feature resolution ------------------------------------------------------

# The feature name becomes a directory, so it has to be a slug — but callers
# hold human project names ("Autenticação V2"), not slugs, so normalize instead
# of refusing.
#
# A URL or a path is refused rather than normalized, on purpose. Mangling
# https://linear.app/acme/project/checkout-v2-9f3a into a directory name is how
# two slightly different copy-pastes of the same project become two graphs, each
# holding half the nodes. Resolving a URL needs the issue tracker, which is the
# skill's job (it has MCP); by the time a name reaches here it must already be
# the project's name.
slugify_feature() {
  local raw="$1" slug
  case "$raw" in
    *://*|*/*)
      die "init: --feature takes a project NAME, not a URL or path: $raw
    /ship:graph resolves a project URL to its name before calling init." ;;
  esac
  # No transliteration: "Autenticação V2" becomes autentica-o-v2, not
  # autenticacao-v2. Uglier, but the slug is an internal directory name nobody
  # types, and every portable way to fold accents (iconv //TRANSLIT is glibc-only
  # and fails on BSD; sed y/// counts bytes, not characters) buys prettier output
  # at the cost of behaving differently per platform.
  slug="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-' | sed 's/^-//; s/-$//')"
  [ -n "$slug" ] || die "init: --feature has no usable characters: $raw"
  printf '%s' "$slug"
}

resolve_feature() {
  local f="$1"
  if [ -z "$f" ] && [ -f "$ACTIVE_POINTER" ]; then
    f="$(head -1 "$ACTIVE_POINTER")"
  fi
  [ -n "$f" ] || die "no feature given and no active graph ($ACTIVE_POINTER missing) — run 'graph.sh init' first"
  slugify_feature "$f"
}

graph_dir() {
  printf '%s/%s' "$GRAPH_ROOT" "$1"
}

require_graph() {
  [ -f "$1/nodes.tsv" ] || die "no graph at $1 — run 'graph.sh init' first"
}

# --- meta --------------------------------------------------------------------

meta_get() {
  local dir="$1" key="$2"
  [ -f "$dir/meta.tsv" ] || { printf ''; return 0; }
  awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$dir/meta.tsv"
}

meta_set() {
  local dir="$1" key="$2" value="$3" tmp
  tmp="$dir/.meta.tmp"
  touch "$dir/meta.tsv"
  awk -F'\t' -v k="$key" -v v="$value" '
    BEGIN { OFS = "\t" }
    $1 == k { print k, v; done = 1; next }
    { print }
    END { if (!done) print k, v }
  ' "$dir/meta.tsv" > "$tmp"
  mv "$tmp" "$dir/meta.tsv"
}

# One issue, one workspace, one PR — the graph's node granularity IS the PR
# granularity, so this is on unless a run opts out. Graphs created before the
# flag existed have no meta row; absent reads as on for them too, which is the
# behaviour their next claim should get.
node_pr_on() {
  [ "$(meta_get "$1" node_pr)" != "off" ]
}

# --- PR state ----------------------------------------------------------------

# The forge client is resolved through a variable so a test can point it at a
# stub, and so a repo whose client is wrapped keeps working.
GH="${GH_BIN:-gh}"

# There is a forge gate only when there is a forge to gate on: node PRs enabled,
# a client on PATH, and a remote for it to talk about. Without all three nothing
# will ever report a PR merged, and holding every dependent behind a signal that
# cannot arrive would deadlock a perfectly good local run.
forge_gate_on() {
  local dir="$1"
  node_pr_on "$dir" || return 1
  command -v "$GH" >/dev/null 2>&1 || return 1
  [ -n "$(git remote 2>/dev/null | head -1)" ] || return 1
  return 0
}

pr_status_file() { printf '%s/pr-status.tsv' "$1"; }

pr_status_get() {
  local dir="$1" id="$2" col="$3" f
  f="$(pr_status_file "$dir")"
  [ -f "$f" ] || { printf ''; return 0; }
  awk -F'\t' -v id="$id" -v c="$col" '$1 == id { print $c; exit }' "$f"
}

pr_status_set() {
  local dir="$1" id="$2" number="$3" state="$4" url="$5" f tmp
  f="$(pr_status_file "$dir")"
  tmp="$dir/.pr-status.tmp"
  touch "$f"
  awk -F'\t' -v OFS='\t' -v id="$id" -v n="$number" -v s="$state" -v u="$url" '
    $1 == id { print id, n, s, u; done = 1; next }
    { print }
    END { if (!done) print id, n, s, u }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}

json_field() {
  printf '%s' "$1" | tr -d ' \n' | sed -n "s/.*\"$2\":\"\{0,1\}\([^,\"}]*\).*/\1/p" | head -1
}

# Asks the forge what actually happened to this node's PR. Nothing here is
# inferred from local git: a branch being an ancestor of the base proves a
# rebase, not a merge, and that difference is the whole point of this gate.
#
# Prints "<state>\t<number>\t<url>". state is the forge's own (OPEN, MERGED,
# CLOSED), or `none` when the client found no PR for that branch.
pr_probe() {
  local dir="$1" id="$2" branch out
  branch="$(node_field "$dir" "$id" 8)"
  [ -n "$branch" ] || { printf 'none\t\t'; return 0; }
  out="$("$GH" pr view "$branch" --json number,state,url 2>"$dir/pr-$id.log" || true)"
  [ -n "$out" ] || { printf 'none\t\t'; return 0; }
  printf '%s\t%s\t%s' \
    "$(json_field "$out" state)" "$(json_field "$out" number)" "$(json_field "$out" url)"
}

# --- nodes -------------------------------------------------------------------

node_field() {
  local dir="$1" id="$2" col="$3"
  awk -F'\t' -v id="$id" -v c="$col" '$1 == id { print $c; exit }' "$dir/nodes.tsv"
}

node_exists() {
  local dir="$1" id="$2"
  awk -F'\t' -v id="$id" '$1 == id { found = 1; exit } END { exit !found }' "$dir/nodes.tsv"
}

node_set() {
  local dir="$1" id="$2" col="$3" value="$4" tmp
  tmp="$dir/.nodes.tmp"
  awk -F'\t' -v OFS='\t' -v target="$id" -v c="$col" -v v="$value" '
    $1 == target { $c = v }
    { print }
  ' "$dir/nodes.tsv" > "$tmp"
  mv "$tmp" "$dir/nodes.tsv"
}

nodes_with_status() {
  local dir="$1" status="$2"
  awk -F'\t' -v s="$status" '$6 == s { print $1 }' "$dir/nodes.tsv" | sort
}

count_status() {
  nodes_with_status "$1" "$2" | sed '/^$/d' | wc -l | tr -d ' '
}

# Tab is IFS *whitespace*, so `IFS=$'\t' read` silently collapses runs of it and
# an empty repo/deps field shifts every later column. Rows are therefore always
# fed through this first. US (\037) is not IFS whitespace, so empty fields
# survive — and unlike \001 it is not the byte bash reserves internally (CTLESC),
# which makes \001 unusable as an IFS delimiter.
US="$(printf '\037')"

nodes_rows() {
  tr '\t' '\037' < "$1/nodes.tsv"
}

log_line() {
  local dir="$1" msg="$2"
  printf -- '- %s — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$dir/graph-log.md"
}

# --- JSON --------------------------------------------------------------------

# Minimal reader for the nodes.json contract: a flat array of objects whose
# values are strings, string arrays, numbers or null. Emits one TSV row per
# object (id, repo, title, deps, files) — deps/files as comma-joined lists.
# Deliberately not a general JSON parser: the contract is produced by /ship:graph
# itself, and a linear scan stays testable in CI without jq/python/node.
parse_nodes_json() {
  awk '
    function readstr(p,   out, ch) {
      p++
      out = ""
      while (p <= n) {
        ch = substr(buf, p, 1)
        if (ch == "\\") {
          p++
          ch = substr(buf, p, 1)
          if (ch == "n" || ch == "t" || ch == "r") { out = out " "; p++ }
          else if (ch == "u") { out = out "?"; p += 5 }
          else { out = out ch; p++ }
          continue
        }
        if (ch == "\"") { p++; break }
        out = out ch
        p++
      }
      S = out
      return p
    }
    function setfield(k, v) {
      if (k == "id") id = v
      else if (k == "repo") repo = v
      else if (k == "title") title = v
      else if (k == "deps") deps = v
      else if (k == "files") files = v
    }
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      i = 1
      depth = 0
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == "{") {
          depth++
          if (depth == 1) { id = ""; repo = ""; title = ""; deps = ""; files = "" }
          i++
          continue
        }
        if (c == "}") {
          if (depth == 1) printf "%s\t%s\t%s\t%s\t%s\n", id, repo, title, deps, files
          depth--
          i++
          continue
        }
        if (c == "\"" && depth == 1) {
          i = readstr(i)
          key = S
          while (i <= n && substr(buf, i, 1) ~ /[ \t\r\n:]/) i++
          c2 = substr(buf, i, 1)
          if (c2 == "\"") {
            i = readstr(i)
            setfield(key, S)
          } else if (c2 == "[") {
            i++
            arr = ""
            while (i <= n) {
              c3 = substr(buf, i, 1)
              if (c3 == "]") { i++; break }
              if (c3 == "\"") { i = readstr(i); arr = (arr == "" ? S : arr "," S); continue }
              i++
            }
            setfield(key, arr)
          } else {
            v = ""
            while (i <= n && substr(buf, i, 1) !~ /[,}\]\r\n\t ]/) { v = v substr(buf, i, 1); i++ }
            if (v == "null") v = ""
            setfield(key, v)
          }
          continue
        }
        i++
      }
    }
  '
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_str_or_null() {
  if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

json_array() {
  local csv="$1" out="" item
  [ -z "$csv" ] && { printf '[]'; return 0; }
  local IFS=','
  for item in $csv; do
    [ -z "$item" ] && continue
    out="$out, \"$(json_escape "$item")\""
  done
  printf '[%s]' "${out#, }"
}

# graph.json is the readable, shareable projection of nodes.tsv + meta.tsv —
# re-rendered on every mutation so it never drifts from the state it describes.
render_json() {
  local dir="$1" out="$dir/.graph.json.tmp"
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "feature": "%s",\n' "$(json_escape "$(meta_get "$dir" feature)")"
    printf '  "mode": "%s",\n' "$(json_escape "$(meta_get "$dir" mode)")"
    printf '  "driver": "%s",\n' "$(json_escape "$(meta_get "$dir" driver)")"
    printf '  "base_branch": "%s",\n' "$(json_escape "$(meta_get "$dir" base_branch)")"
    printf '  "max_in_flight": %s,\n' "$(meta_get "$dir" max_in_flight)"
    printf '  "nodes": [\n'
    local first=1 id repo title deps files status wt branch attempts blocked
    while IFS="$US" read -r id repo title deps files status wt branch attempts blocked; do
      [ -n "$id" ] || continue
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    {\n'
      printf '      "id": "%s",\n' "$(json_escape "$id")"
      printf '      "repo": %s,\n' "$(json_str_or_null "$repo")"
      printf '      "title": %s,\n' "$(json_str_or_null "$title")"
      printf '      "deps": %s,\n' "$(json_array "$deps")"
      printf '      "files": %s,\n' "$(json_array "$files")"
      printf '      "status": "%s",\n' "$(json_escape "$status")"
      printf '      "worktree": %s,\n' "$(json_str_or_null "$wt")"
      printf '      "branch": %s,\n' "$(json_str_or_null "$branch")"
      printf '      "attempts": %s,\n' "${attempts:-0}"
      printf '      "blocked_by_conflict": %s,\n' "$(json_str_or_null "$blocked")"
      printf '      "pr": %s,\n' "$(json_str_or_null "$(pr_status_get "$dir" "$id" 2)")"
      printf '      "pr_state": %s,\n' "$(json_str_or_null "$(pr_status_get "$dir" "$id" 3)")"
      printf '      "pr_url": %s\n' "$(json_str_or_null "$(pr_status_get "$dir" "$id" 4)")"
      printf '    }'
    done < <(nodes_rows "$dir")
    [ "$first" -eq 1 ] || printf '\n'
    printf '  ],\n'
    printf '  "pr_gate": { "last_merged": %s, "awaiting_merge": %s }\n' \
      "$(json_str_or_null "$(meta_get "$dir" last_merged)")" \
      "$(count_status "$dir" landed)"
    printf '}\n'
  } > "$out"
  mv "$out" "$dir/graph.json"
}

# --- edges -------------------------------------------------------------------

# Footprint overlap: exact path match, or one path being a directory prefix of
# the other. `src/api` collides with `src/api/routes.ts`; `src/apiv2` does not.
files_overlap() {
  local a_csv="$1" b_csv="$2" a b
  [ -n "$a_csv" ] && [ -n "$b_csv" ] || return 1
  local old_ifs="$IFS"
  IFS=','
  for a in $a_csv; do
    [ -n "$a" ] || continue
    a="${a%/}"
    for b in $b_csv; do
      [ -n "$b" ] || continue
      b="${b%/}"
      if [ "$a" = "$b" ]; then IFS="$old_ifs"; return 0; fi
      case "$b" in "$a"/*) IFS="$old_ifs"; return 0 ;; esac
      case "$a" in "$b"/*) IFS="$old_ifs"; return 0 ;; esac
    done
  done
  IFS="$old_ifs"
  return 1
}

# A dependency is satisfied when its PR is MERGED on the forge — not when its
# pipeline finished locally. The two came apart in practice: a node whose work
# only exists on an unmerged branch is not something the next node can build on,
# and admitting its dependent against a base that does not contain it is how a
# dependent re-implements or contradicts work that is still in review.
deps_satisfied() {
  local dir="$1" id="$2" deps d st
  deps="$(node_field "$dir" "$id" 4)"
  [ -n "$deps" ] || return 0
  local old_ifs="$IFS"
  IFS=','
  for d in $deps; do
    [ -n "$d" ] || continue
    st="$(node_field "$dir" "$d" 6)"
    if [ -z "$st" ] || [ "$st" != "merged" ]; then IFS="$old_ifs"; return 1; fi
  done
  IFS="$old_ifs"
  return 0
}

# --- init --------------------------------------------------------------------

# The base is what every node branches from AND what every node PR targets, so
# it has to be the branch the forge actually merges into. An ephemeral branch
# only the coordinator ever sees would make every node PR a PR against a
# coordinator-local fiction: merging it would land the work nowhere real, and
# the graph's own "merged" signal would mean nothing outside this machine.
#
# The remote's HEAD is the honest answer; the conventional local names and then
# the checked-out branch are the fallbacks for a repo with no remote.
default_branch() {
  local remote d
  remote="$(git config --get "branch.$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true).remote" 2>/dev/null || true)"
  if [ -z "$remote" ] && git remote get-url origin >/dev/null 2>&1; then remote="origin"; fi
  if [ -z "$remote" ] && [ "$(git remote 2>/dev/null | awk 'END { print NR + 0 }')" = "1" ]; then
    remote="$(git remote)"
  fi
  if [ -n "$remote" ]; then
    d="$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s|^$remote/||" || true)"
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  fi
  for d in main master; do
    git show-ref --verify --quiet "refs/heads/$d" && { printf '%s' "$d"; return 0; }
  done
  d="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  printf '%s' "${d:-main}"
}

# Local mode keeps the spec in ship/changes/<feature>/, and /ship:spec leaves it
# UNCOMMITTED — only /ship:pr ever commits. Every node workspace is branched from
# the base ref, so an uncommitted spec simply is not there: the node's pipeline
# reaches its context state, finds no proposal/design/tasks, and stops.
#
# Sealing it onto the base once, here, is the only placement that works. Copying
# it per node instead would have every node commit the same files and collide at
# merge time.
seal_spec() {
  local dir="$1" feature="$2" spec_dir="ship/changes/$feature" head_branch
  [ -d "$spec_dir" ] || return 0
  # Sealing means committing onto whatever is checked out here, and the nodes
  # branch from the BASE. When the two differ the commit would land somewhere no
  # node ever reads, so say so instead of leaving a silent gap.
  head_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$head_branch" ] && [ "$head_branch" != "$(meta_get "$dir" base_branch)" ]; then
    log_line "$dir" "spec NOT sealed: HEAD is $head_branch but nodes branch from $(meta_get "$dir" base_branch) — check out the base branch and re-run init if the nodes need the spec"
    return 0
  fi
  git add -- "$spec_dir" >/dev/null 2>&1 || return 0
  git diff --cached --quiet -- "$spec_dir" 2>/dev/null && return 0
  git commit -q -m "docs($feature): spec artifacts for the work graph" -- "$spec_dir" >/dev/null 2>&1 || return 0
  log_line "$dir" "spec sealed onto $(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD) so node workspaces inherit it"
}

# --- driver selection --------------------------------------------------------

# With no --driver given, ask every driver whether it can run here and how
# strongly it wants the job, then take the keenest. The scheduler stays
# runtime-agnostic: it globs driver files, reads two numbers and picks — it never
# learns what any of them is. A new driver becomes selectable by existing.
#
# This replaces a fixed default of the ONE driver that spawns nothing, so the
# common case used to be a graph whose every workspace had to be made by hand.
# Selecting in a script rather than describing the choice in a skill is the point:
# a rule written as prose is a rule that sometimes does not run.
# Prints "<name><TAB><workspaces-label>" so the caller can report what the
# elected driver actually produces without knowing which driver it got. The
# label is the driver's own words, echoed verbatim.
autoselect_driver() {
  local f name out ready prio ws best="" best_prio="" best_ws=""
  for f in "$HOOK_DIR"/driver-*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"
    name="${name#driver-}"
    out="$(bash "$f" probe 2>/dev/null || true)"
    ready="$(printf '%s' "$out" | sed -n 's/^ready=//p' | head -1)"
    [ "$ready" = "1" ] || continue
    prio="$(printf '%s' "$out" | sed -n 's/^priority=//p' | head -1)"
    ws="$(printf '%s' "$out" | sed -n 's/^workspaces=//p' | head -1)"
    # A driver that claims readiness without a usable priority still gets to
    # run; it just sorts last. Refusing it would make a malformed probe look
    # like an absent driver.
    case "$prio" in ''|*[!0-9]*) prio=99 ;; esac
    if [ -z "$best_prio" ] || [ "$prio" -lt "$best_prio" ]; then
      best="$name"
      best_prio="$prio"
      best_ws="$ws"
    fi
  done
  [ -n "$best" ] || return 0
  printf '%s\t%s' "$best" "$best_ws"
}

# A probe-elected driver was elected against the runtimes that answered AT THAT
# MOMENT. The real cost of never revisiting it was measured: a graph whose first
# init hit a broken runtime fell back to the driver that spawns nothing, and
# every later batch — for hours, across sessions, long after the runtime was
# fixed — kept using it, because the election is written to meta once and the
# only thing that could revisit it was an operator remembering to. So a run that
# was supposed to open one app workspace per issue quietly opened none, twice
# over, and the degradation was invisible in every status it printed.
#
# Re-electing here makes recovery automatic instead of remembered. It is safe
# only while no node is HELD by the current driver — an in-flight node can be
# collected, waited on and stopped only through the driver that dispatched it —
# which is the same guard `set --driver` uses.
#
# A driver named explicitly by a human is never re-elected: `--driver local` has
# to mean local, or pinning a runtime would be impossible. An election recorded
# by a Ship older than this field is treated as a probe, so those graphs heal too.
reelect_driver() {
  local dir="$1" cur chosen busy sel best ws
  cur="$(meta_get "$dir" driver)"
  chosen="$(meta_get "$dir" driver_chosen_by)"
  [ "$chosen" != "explicit" ] || return 0

  busy="$(nodes_with_status "$dir" in_flight | tr -d '[:space:]')"
  [ -z "$busy" ] || return 0

  sel="$(autoselect_driver)"
  best="${sel%%$'\t'*}"
  ws="${sel#*$'\t'}"
  [ -n "$best" ] || return 0
  meta_set "$dir" driver_workspaces "$ws"
  [ "$best" != "$cur" ] || return 0

  meta_set "$dir" driver "$best"
  meta_set "$dir" driver_chosen_by probe
  log_line "$dir" "driver re-elected $cur → $best (probe; no node held by $cur)"
}

cmd_init() {
  local feature="" from="" driver="" max_in_flight="2" base_branch="" mode="local" fresh=0 default_repo="" chosen_by="explicit" node_pr="on"

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --from) from="$2"; shift 2 ;;
      --driver) driver="$2"; shift 2 ;;
      --max-in-flight) max_in_flight="$2"; shift 2 ;;
      --base-branch) base_branch="$2"; shift 2 ;;
      --mode) mode="$2"; shift 2 ;;
      --repo) default_repo="$2"; shift 2 ;;
      --node-pr) node_pr="$2"; shift 2 ;;
      --fresh) fresh=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  [ -n "$feature" ] || die "init: --feature is required"
  feature="$(slugify_feature "$feature")"
  [ -n "$from" ] || die "init: --from <nodes.json> is required"
  [ -f "$from" ] || die "init: nodes file not found: $from"
  case "$max_in_flight" in
    ''|*[!0-9]*) die "init: --max-in-flight must be a positive integer: $max_in_flight" ;;
  esac
  [ "$max_in_flight" -ge 1 ] || die "init: --max-in-flight must be >= 1"
  case "$mode" in linear|local) ;; *) die "init: --mode must be linear or local: $mode" ;; esac
  case "$node_pr" in on|off) ;; *) die "init: --node-pr must be on or off: $node_pr" ;; esac
  local driver_workspaces=""
  if [ -z "$driver" ]; then
    local sel
    sel="$(autoselect_driver)"
    driver="${sel%%$'\t'*}"
    driver_workspaces="${sel#*$'\t'}"
    [ -n "$driver" ] || die "init: no driver reported itself ready here — pass --driver <name> explicitly"
    chosen_by="probe"
  fi
  valid_id "$driver" || die "init: invalid driver name: $driver"
  [ -f "$HOOK_DIR/driver-$driver.sh" ] || die "init: no driver at $HOOK_DIR/driver-$driver.sh"
  [ -n "$driver_workspaces" ] || driver_workspaces="$(bash "$HOOK_DIR/driver-$driver.sh" probe 2>/dev/null | sed -n 's/^workspaces=//p' | head -1 || true)"

  local dir
  dir="$(graph_dir "$feature")"

  # A live graph is never silently discarded: the fix-loop counters and the
  # in-flight node claims live here, and dropping them restarts loops that are
  # supposed to be capped.
  #
  # Reported as RESUME/exit 3 rather than an error, mirroring pipeline.sh init.
  # A coordinator whose context was compacted mid-run re-invokes /ship:graph and
  # must rejoin the run; if this failed with "pass --fresh to discard it", the
  # obvious next move is to pass --fresh — and that is precisely the destructive
  # one. Exit 3 says "already live, go to the loop" with no such invitation.
  # Both files, not just nodes.tsv: a half-written directory is debris from a
  # failed init, not a live graph, and reporting RESUME over it strands the
  # caller — the corrected init gets refused and only --fresh clears it, which
  # is the exact reflex the RESUME contract exists to prevent.
  if [ -f "$dir/nodes.tsv" ] && [ -f "$dir/meta.tsv" ] && [ "$fresh" -eq 0 ]; then
    printf 'RESUME\n'
    printf 'feature=%s\n' "$feature"
    printf 'graph=%s\n' "$dir/graph.json"
    printf 'nodes=%s\n' "$(awk 'END { print NR }' "$dir/nodes.tsv")"
    printf 'inflight=%s\n' "$(count_status "$dir" in_flight)"
    printf 'landed=%s\n' "$(count_status "$dir" landed)"
    printf 'merged=%s\n' "$(count_status "$dir" merged)"
    # A re-init almost always means "the driver I picked does not work here" or
    # "give me more slots" — not "throw the run away". Naming the non-destructive
    # command here is what keeps the next reflex off --fresh.
    if [ "$driver" != "$(meta_get "$dir" driver)" ] || [ "$max_in_flight" != "$(meta_get "$dir" max_in_flight)" ]; then
      printf 'reconfigure=graph.sh set --feature %s --driver %s --max-in-flight %s\n' \
        "$feature" "$driver" "$max_in_flight"
    fi
    exit 3
  fi

  [ -n "$base_branch" ] || base_branch="$(default_branch)"

  mkdir -p "$dir"
  # --fresh has to clear EVERY per-run file, not just the two that describe the
  # graph. Leaving the driver's own state behind means the next run's first
  # `wait` reports done= for nodes it never dispatched — a fabricated completion
  # signal surviving a reset, which is exactly what the observe-the-artifact
  # rule exists to prevent. Stall and progress counters are just as poisonous.
  if [ "$fresh" -eq 1 ]; then
    rm -f "$dir"/iteration-*.txt "$dir"/driver-*.txt "$dir"/progress-*.txt \
          "$dir"/stall-*.txt "$dir"/why-*.txt "$dir"/pr-*.log \
          "$dir/pr-status.tsv" "$dir/nodes.tsv" "$dir/meta.tsv"
  fi

  local parsed
  parsed="$(parse_nodes_json < "$from")"
  [ -n "$parsed" ] || die "init: no nodes parsed from $from (expected a JSON array of objects with an \"id\")"

  # Staged, never written in place. An init that dies mid-validation must leave
  # the directory exactly as it found it, or the next init inherits the debris.
  local staged="$dir/.nodes.staged"
  : > "$staged"
  local id repo title deps files seen=""
  while IFS="$US" read -r id repo title deps files; do
    [ -n "$id" ] || { rm -f "$staged"; die "init: a node in $from has no \"id\""; }
    valid_id "$id" || { rm -f "$staged"; die "init: invalid node id (allowed: [a-zA-Z0-9_-]): $id"; }
    case " $seen " in *" $id "*) rm -f "$staged"; die "init: duplicate node id in $from: $id" ;; esac
    seen="$seen $id"
    printf '%s\t%s\t%s\t%s\t%s\tpending\t\t\t0\t\n' "$id" "$repo" "$title" "$deps" "$files" >> "$staged"
  done < <(printf '%s\n' "$parsed" | tr '\t' '\037')

  # Dangling dependency edges are a spec bug, not a runtime condition: catching
  # them here beats emitting a deadlock `ask` halfway through the run.
  local d
  # Default IFS on purpose: the awk below emits "<id> <deps>" space-separated,
  # and IFS= would put the whole line in $id, silently skipping every check.
  while read -r id deps; do
    [ -n "$deps" ] || continue
    local old_ifs="$IFS"
    IFS=','
    for d in $deps; do
      [ -n "$d" ] || continue
      case " $seen " in
        *" $d "*) ;;
        *) IFS="$old_ifs"; rm -f "$staged"; die "init: node $id depends on unknown node: $d" ;;
      esac
    done
    IFS="$old_ifs"
  done < <(awk -F'\t' '{ print $1, $4 }' "$staged")

  mv "$staged" "$dir/nodes.tsv"

  meta_set "$dir" feature "$feature"
  meta_set "$dir" mode "$mode"
  meta_set "$dir" driver "$driver"
  # Without this, every election looks the same to a later reader, so a fallback
  # forced by a broken runtime is indistinguishable from a deliberate pin — and
  # re-election cannot tell which ones it is allowed to revisit.
  meta_set "$dir" driver_chosen_by "$chosen_by"
  meta_set "$dir" driver_workspaces "$driver_workspaces"
  meta_set "$dir" base_branch "$base_branch"
  meta_set "$dir" max_in_flight "$max_in_flight"
  meta_set "$dir" repo "$default_repo"
  meta_set "$dir" node_pr "$node_pr"
  meta_set "$dir" last_merged ""

  mkdir -p "$GRAPH_ROOT"
  printf '%s\n' "$feature" > "$ACTIVE_POINTER"

  render_json "$dir"
  log_line "$dir" "init feature=$feature driver=$driver ($chosen_by) mode=$mode max_in_flight=$max_in_flight base=$base_branch nodes=$(wc -l < "$dir/nodes.tsv" | tr -d ' ')"
  [ "$mode" = "local" ] && seal_spec "$dir" "$feature"

  printf 'INIT %s\n' "$feature"
  printf 'feature=%s\n' "$feature"
  printf 'graph=%s\n' "$dir/graph.json"
  printf 'nodes=%s\n' "$(wc -l < "$dir/nodes.tsv" | tr -d ' ')"
  printf 'driver=%s\n' "$driver"
  printf 'driver_chosen_by=%s\n' "$chosen_by"
}

# --- set ---------------------------------------------------------------------

set_usage() {
  echo "usage: graph.sh set [--feature <f>] [--driver <d>] [--max-in-flight N] [--node-pr on|off]" >&2
  echo "  changes a live graph's runtime knobs without touching nodes or counters" >&2
}

# The escape hatch that has to exist. Before this, the only way to change the
# driver on a live graph was re-init, which the RESUME guard refuses — leaving
# --fresh as the sole way through, and --fresh discards the in-flight claims and
# fix-loop counters the guard exists to protect. A driver that turns out not to
# work in this environment (no CLI, no permission to dispatch) is discovered
# AFTER init by construction, so "start over" was the wrong and only answer.
#
# Only the knobs that carry no node state are settable. base_branch is not:
# every workspace is already branched from it and every open node PR already
# targets it, so changing it mid-run would leave the conflict edges reading
# against a base the nodes never saw.
cmd_set() {
  local feature="" driver="" max_in_flight="" node_pr="" changed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --driver) driver="$2"; shift 2 ;;
      --max-in-flight) max_in_flight="$2"; shift 2 ;;
      --node-pr) node_pr="$2"; shift 2 ;;
      -h|--help) set_usage; exit 0 ;;
      *) set_usage; exit 1 ;;
    esac
  done
  [ -n "$driver" ] || [ -n "$max_in_flight" ] || [ -n "$node_pr" ] || die "set: give --driver, --max-in-flight and/or --node-pr"

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"

  # Read at claim time, so flipping it mid-run only reaches nodes not yet
  # claimed — the ones already carrying a pr-mode marker keep the contract they
  # were dispatched under.
  if [ -n "$node_pr" ]; then
    case "$node_pr" in on|off) ;; *) die "set: --node-pr must be on or off: $node_pr" ;; esac
    meta_set "$dir" node_pr "$node_pr"
    log_line "$dir" "node_pr → $node_pr"
    printf 'node_pr=%s\n' "$node_pr"
    changed=1
  fi

  if [ -n "$max_in_flight" ]; then
    case "$max_in_flight" in ''|*[!0-9]*) die "set: --max-in-flight must be a positive integer: $max_in_flight" ;; esac
    [ "$max_in_flight" -ge 1 ] || die "set: --max-in-flight must be >= 1"
    meta_set "$dir" max_in_flight "$max_in_flight"
    log_line "$dir" "max_in_flight → $max_in_flight"
    printf 'max_in_flight=%s\n' "$max_in_flight"
    changed=1
  fi

  if [ -n "$driver" ]; then
    valid_id "$driver" || die "set: invalid driver name: $driver"
    [ -f "$HOOK_DIR/driver-$driver.sh" ] || die "set: no driver at $HOOK_DIR/driver-$driver.sh"
    # An in-flight node was dispatched THROUGH the old driver and can only be
    # collected, waited on and stopped through it. Swapping underneath it orphans
    # a worker that keeps running and billing with nothing able to reach it.
    local busy
    busy="$(nodes_with_status "$dir" in_flight | tr '\n' ' ')"
    busy="$(printf '%s' "$busy" | sed 's/ *$//')"
    if [ -n "$busy" ]; then
      die "set: cannot change the driver while node(s) are still held by the current one: $busy
    Let them finish, or release them first: graph.sh abort (stops the workers, keeps the workspaces)."
    fi
    local prev prev_ws ws
    prev="$(meta_get "$dir" driver)"
    prev_ws="$(meta_get "$dir" driver_workspaces)"
    ws="$(bash "$HOOK_DIR/driver-$driver.sh" probe 2>/dev/null | sed -n 's/^workspaces=//p' | head -1 || true)"
    meta_set "$dir" driver "$driver"
    # Naming a driver by hand pins it: re-election must not undo the operator's
    # choice on the very next `next`.
    meta_set "$dir" driver_chosen_by explicit
    meta_set "$dir" driver_workspaces "$ws"
    log_line "$dir" "driver $prev → $driver (explicit; workspaces: ${ws:-unknown})"
    printf 'driver=%s\n' "$driver"
    printf 'previous_driver=%s\n' "$prev"
    printf 'workspaces=%s\n' "$ws"
    # Pinning by hand is also opting OUT of automatic recovery, and the run that
    # made this necessary spent hours on a driver nobody had chosen on purpose.
    # Saying what changed here is what makes the trade visible at the moment it
    # is made, in the same transcript the operator is already reading.
    if [ -n "$prev_ws" ] && [ "$prev_ws" != "$ws" ]; then
      printf 'previous_workspaces=%s\n' "$prev_ws"
    fi
    printf 'note=pinned — this driver is now used regardless of what else becomes available; undo with: graph.sh set --driver <name>\n'
    changed=1
  fi

  render_json "$dir"
  printf 'feature=%s\n' "$(meta_get "$dir" feature)"
  printf 'changed=%s\n' "$changed"
}

# --- nodes --from-tasks ------------------------------------------------------

# Local mode's tasks.md → nodes.json conversion. Deterministic on purpose: the
# `## Files` / `## Deps` blocks /ship:spec emits are already structured, so this
# needs no model in the loop.
cmd_nodes() {
  local tasks=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-tasks) tasks="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  [ -n "$tasks" ] || die "nodes: --from-tasks <tasks.md> is required"
  [ -f "$tasks" ] || die "nodes: file not found: $tasks"

  awk '
    function flush() {
      if (id == "") return
      if (out != "") printf ",\n"
      printf "  { \"id\": \"%s\", \"repo\": \"%s\", \"title\": \"%s\", \"deps\": [%s], \"files\": [%s] }", id, repo, title, deps, files
      out = "x"
    }
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN { printf "[\n" }
    /^###+[[:space:]]/ {
      flush()
      line = $0
      sub(/^###+[[:space:]]*/, "", line)
      id = line
      sub(/[[:space:]].*$/, "", id)
      gsub(/[^a-zA-Z0-9_-]/, "", id)
      title = line
      sub(/^[^[:space:]]+[[:space:]]*[-—:]*[[:space:]]*/, "", title)
      title = esc(title)
      repo = ""; deps = ""; files = ""; section = ""
      next
    }
    /^##[[:space:]]+Files[[:space:]]*$/ { section = "files"; next }
    /^##[[:space:]]+Deps[[:space:]]*$/  { section = "deps";  next }
    /^##[[:space:]]+Repo[[:space:]]*$/  { section = "repo";  next }
    /^#/ { section = ""; next }
    # A horizontal rule ends a section. Without this, "---" survives the dep
    # cleanup as a node id of "--" and every task depends on a node that cannot
    # exist, which deadlocks the whole graph before it starts.
    /^[[:space:]]*(-{3,}|\*{3,}|_{3,})[[:space:]]*$/ { section = ""; next }
    section == "files" {
      v = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      sub(/^[[:space:]]+/, "", v)
      sub(/^(create|modify|delete|criar|modificar|remover)[[:space:]]+/, "", v)
      gsub(/`/, "", v)
      sub(/[[:space:]].*$/, "", v)
      # Accept only things shaped like a path. The section routinely runs on into
      # acceptance criteria and Gherkin, and prose swallowed into `files` becomes
      # a bogus conflict edge that blocks unrelated nodes forever.
      if (v !~ /^[A-Za-z0-9_.@-]*\/[A-Za-z0-9_.\/@-]+$/ && v !~ /^[A-Za-z0-9_.@-]+\.[A-Za-z0-9]+$/) next
      files = files (files == "" ? "" : ", ") "\"" esc(v) "\""
      next
    }
    section == "deps" {
      v = $0
      gsub(/^[[:space:]]*-?[[:space:]]*|[[:space:]]+$/, "", v)
      gsub(/`/, "", v)
      if (v == "" || tolower(v) == "none" || tolower(v) == "nenhuma") next
      # A dep must look like a task id: starts alphanumeric, no pure punctuation.
      if (v !~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/) next
      deps = deps (deps == "" ? "" : ", ") "\"" v "\""
      next
    }
    section == "repo" {
      v = $0
      gsub(/^[[:space:]]*-?[[:space:]]*|[[:space:]]+$/, "", v)
      gsub(/`/, "", v)
      if (v != "" && repo == "") repo = esc(v)
      next
    }
    END { flush(); printf "\n]\n" }
  ' "$tasks"
}

# --- transitions -------------------------------------------------------------

transition() {
  local dir="$1" id="$2" from_csv="$3" to="$4"
  node_exists "$dir" "$id" || die "unknown node: $id"
  local cur
  cur="$(node_field "$dir" "$id" 6)"
  case ",$from_csv," in
    *",$cur,"*) ;;
    *) die "$id is '$cur' — cannot move to '$to' (expected one of: $from_csv)" ;;
  esac
  node_set "$dir" "$id" 6 "$to"
  log_line "$dir" "$id $cur → $to"
}

cmd_claim() {
  local feature="" id="" wt="" branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --worktree) wt="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *) if [ -z "$id" ]; then id="$1"; else usage; exit 1; fi; shift ;;
    esac
  done
  [ -n "$id" ] || die "claim: <task> is required"
  [ -n "$wt" ] || die "claim: --worktree <path> is required"
  [ -n "$branch" ] || die "claim: --branch <ref> is required"
  [ -d "$wt" ] || die "claim: worktree path does not exist: $wt"

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"

  node_set "$dir" "$id" 7 "$wt"
  node_set "$dir" "$id" 8 "$branch"
  node_set "$dir" "$id" 9 "$(( $(node_field "$dir" "$id" 9) + 1 ))"
  node_set "$dir" "$id" 10 ""
  transition "$dir" "$id" "pending,ready" in_flight

  # Federated homolog: the node's pipeline must not stop for a per-task
  # acceptance prompt — the graph presents every report in one batch at the end.
  # The marker has to land in the workspace's scratch dir, which only exists once
  # the workspace does, i.e. here and not a step earlier.
  local scratch="$wt/.context/ship-run/$id"
  mkdir -p "$scratch"
  printf 'defer\n' > "$scratch/homolog-mode.txt"

  # Tells the node's pipeline it has a coordinator to talk to: instead of an
  # `ask` no one is there to answer, it posts the question to ask.md in this same
  # dir and `graph.sh next` brings it up here.
  printf '%s\n' "$dir" > "$scratch/graph-node.txt"
  rm -f "$scratch/ask.md" "$scratch/answer.txt"

  # One issue, one PR: the node's own pipeline opens it, from the workspace that
  # holds the diff, so the commits are the atomic ones /ship:pr writes instead of
  # the single blob seal_workspace falls back to. The base is the graph's base —
  # the real trunk — and the node's own /ship:pr syncs onto it before pushing,
  # with the context of the change it just implemented. A node is only dispatched
  # once every dependency's PR is merged there, so its diff is its own work alone.
  local node_pr_state="off"
  if node_pr_on "$dir"; then
    node_pr_state="on"
    {
      printf 'mode=graph\n'
      printf 'base=%s\n' "$(meta_get "$dir" base_branch)"
    } > "$scratch/pr-mode.txt"
  else
    rm -f "$scratch/pr-mode.txt"
  fi

  # Baseline the progress counter here, not on the first poll. Without it the
  # first poll always reads as progress (no previous value to compare against)
  # and the stall cap silently needs one extra round.
  printf '%s\n' "$(awk 'END { print NR + 0 }' "$scratch/dispatch-log.md" 2>/dev/null || echo 0)" \
    > "$dir/progress-$id.txt"
  rm -f "$dir/stall-$id.txt" "$dir/why-$id.txt"

  render_json "$dir"

  printf 'claimed=%s\n' "$id"
  printf 'worktree=%s\n' "$wt"
  printf 'branch=%s\n' "$branch"
  printf 'homolog_mode=defer\n'
  printf 'node_pr=%s\n' "$node_pr_state"
}

# /ship:run leaves its work UNCOMMITTED — develop writes to the tree and only
# /ship:pr ever commits. A node whose branch carries no commit merges nothing, so
# the graph would integrate an empty change and call it green. Sealing the
# workspace here, in bash, keeps that off the worker's judgment entirely.
seal_workspace() {
  local dir="$1" id="$2" wt title feature
  wt="$(node_field "$dir" "$id" 7)"
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" add -A >/dev/null 2>&1 || true
  # tasks.md is the one file every node edits (each marks its own task done),
  # so committing it per node puts N branches in contention over one file for no
  # gain — the graph already sealed the spec onto the base at init. Per-node
  # reports are uniquely named and stay in.
  feature="$(meta_get "$dir" feature)"
  [ -n "$feature" ] && git -C "$wt" reset -q -- "ship/changes/$feature/tasks.md" >/dev/null 2>&1
  git -C "$wt" diff --cached --quiet 2>/dev/null && return 0
  title="$(node_field "$dir" "$id" 3)"
  git -C "$wt" commit -q -m "feat($id): ${title:-$id}" >/dev/null 2>&1 || true
  log_line "$dir" "$id workspace sealed into a commit on $(node_field "$dir" "$id" 8)"
}

poll_usage() {
  echo "usage: graph.sh poll [--feature <f>] [--stall-max N]" >&2
}

SETTLE_MERGED=0
SETTLE_AWAITING=0
SETTLE_CLOSED=0

# The forge gate. A landed node has finished its pipeline and opened its PR; what
# happens next happens on the forge, where a human reviews and merges. This reads
# that outcome and nothing else — it never merges, never pushes, never verifies.
#
# A PR closed without merging is a decision, not a pause: leaving the node landed
# would hold every dependent behind a merge that is never coming.
settle_landed() {
  local dir="$1" gated=1 id probe rest state number url
  SETTLE_MERGED=0
  SETTLE_AWAITING=0
  SETTLE_CLOSED=0
  forge_gate_on "$dir" || gated=0

  while IFS= read -r id; do
    [ -n "$id" ] || continue

    if [ "$gated" -eq 0 ]; then
      pr_status_set "$dir" "$id" "" "no-forge" ""
      transition "$dir" "$id" landed merged
      meta_set "$dir" last_merged "$id"
      log_line "$dir" "$id merged — no forge gate here (node PRs off, no forge client, or no remote)"
      printf 'merged=%s\n' "$id"
      SETTLE_MERGED=$((SETTLE_MERGED + 1))
      continue
    fi

    probe="$(pr_probe "$dir" "$id")"
    state="${probe%%	*}"
    rest="${probe#*	}"
    number="${rest%%	*}"
    url="${rest#*	}"
    pr_status_set "$dir" "$id" "$number" "$state" "$url"

    case "$state" in
      MERGED)
        transition "$dir" "$id" landed merged
        meta_set "$dir" last_merged "$id"
        log_line "$dir" "$id PR #$number merged on the forge — its dependents are free"
        printf 'merged=%s\n' "$id"
        SETTLE_MERGED=$((SETTLE_MERGED + 1))
        ;;
      CLOSED)
        node_set "$dir" "$id" 6 failed
        node_set "$dir" "$id" 10 ""
        log_line "$dir" "$id → failed: PR #$number was closed without being merged"
        printf 'pr_closed=%s\n' "$id"
        SETTLE_CLOSED=$((SETTLE_CLOSED + 1))
        ;;
      none)
        log_line "$dir" "$id landed but the forge reports no PR for $(node_field "$dir" "$id" 8)"
        printf 'pr_missing=%s\n' "$id"
        SETTLE_AWAITING=$((SETTLE_AWAITING + 1))
        ;;
      *)
        printf 'awaiting_merge=%s\n' "$id"
        SETTLE_AWAITING=$((SETTLE_AWAITING + 1))
        ;;
    esac
  done < <(nodes_with_status "$dir" landed)
}

# The completion signal, independent of anything a worker chooses to report.
#
# A worker can forget to send a message; it cannot forget to have left
# homolog-approved.txt on disk — pipeline.sh writes that itself, in bash, when
# the run reaches done. So the graph observes the artifact instead of trusting a
# handshake. Progress is dispatch-log.md's row count, which pipeline.sh appends
# on every phase dispatch; a node whose row count has not moved for --stall-max
# consecutive polls is surfaced rather than waited on forever.
cmd_poll() {
  local feature="" stall_max=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --stall-max) stall_max="$2"; shift 2 ;;
      -h|--help) poll_usage; exit 0 ;;
      *) poll_usage; exit 1 ;;
    esac
  done
  case "$stall_max" in ''|*[!0-9]*) die "poll: --stall-max must be a positive integer: $stall_max" ;; esac

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"

  local id wt rows prev stalls landed=0 stalled=0 working=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    wt="$(node_field "$dir" "$id" 7)"
    [ -n "$wt" ] && [ -d "$wt" ] || continue

    if [ -f "$wt/.context/ship-run/$id/homolog-approved.txt" ]; then
      seal_workspace "$dir" "$id"
      transition "$dir" "$id" "in_flight" landed
      rm -f "$dir/progress-$id.txt" "$dir/stall-$id.txt" "$dir/why-$id.txt"
      printf 'landed=%s\n' "$id"
      landed=$((landed + 1))
      continue
    fi

    # No dispatch-log.md at all means the pipeline never ran a single phase in
    # this workspace — the worker was never started, not "started and slow".
    # The two are indistinguishable by row count alone (both read 0), and
    # conflating them is what turns a worker that was never launched into a
    # silent half-hour wait. Recorded so `next` can name the real cause.
    if [ ! -f "$wt/.context/ship-run/$id/dispatch-log.md" ]; then
      printf 'never-started\n' > "$dir/why-$id.txt"
    else
      rm -f "$dir/why-$id.txt"
    fi

    rows="$(awk 'END { print NR + 0 }' "$wt/.context/ship-run/$id/dispatch-log.md" 2>/dev/null || echo 0)"
    prev="$(cat "$dir/progress-$id.txt" 2>/dev/null || true)"
    if [ "$rows" != "$prev" ]; then
      printf '%s\n' "$rows" > "$dir/progress-$id.txt"
      rm -f "$dir/stall-$id.txt"
      # Logged, not just printed: graph-log.md is the only place progress is
      # visible from outside the orchestrator's turn, and a silent poll is
      # indistinguishable from a stuck run for whoever is watching.
      log_line "$dir" "$id working — $((rows > 3 ? rows - 3 : 0)) phase(s) dispatched"
      printf 'working=%s\n' "$id"
      working=$((working + 1))
      continue
    fi

    stalls=$(( $(cat "$dir/stall-$id.txt" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$stalls" > "$dir/stall-$id.txt"
    if [ "$stalls" -ge "$stall_max" ]; then
      if [ -f "$dir/why-$id.txt" ]; then
        log_line "$dir" "$id STALLED — no pipeline ever ran in its workspace across $stalls polls (worker never started)"
        printf 'stalled=%s\n' "$id"
        printf 'never_started=%s\n' "$id"
      else
        log_line "$dir" "$id STALLED — no phase progress across $stalls polls"
        printf 'stalled=%s\n' "$id"
      fi
      stalled=$((stalled + 1))
    else
      log_line "$dir" "$id quiet ($stalls/$stall_max polls with no phase progress)"
      printf 'quiet=%s\n' "$id"
    fi
  done < <(nodes_with_status "$dir" in_flight)

  settle_landed "$dir"

  render_json "$dir"
  printf 'summary=landed:%s working:%s stalled:%s merged:%s awaiting_merge:%s\n' \
    "$landed" "$working" "$stalled" "$SETTLE_MERGED" "$SETTLE_AWAITING"
}

cmd_land() {
  local feature="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *) if [ -z "$id" ]; then id="$1"; else usage; exit 1; fi; shift ;;
    esac
  done
  [ -n "$id" ] || die "land: <task> is required"
  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  seal_workspace "$dir" "$id"
  transition "$dir" "$id" "in_flight" landed
  render_json "$dir"
  printf 'landed=%s\n' "$id"
}

cmd_complete() {
  local feature="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *) if [ -z "$id" ]; then id="$1"; else usage; exit 1; fi; shift ;;
    esac
  done
  [ -n "$id" ] || die "complete: <task> is required"
  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  # The manual counterpart of the forge gate: a node whose work reached the base
  # by a route the forge cannot report (merged by hand, landed in another PR).
  transition "$dir" "$id" "landed" merged
  meta_set "$dir" last_merged "$id"
  render_json "$dir"
  printf 'completed=%s\n' "$id"
}

cmd_fail() {
  local feature="" id="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *) if [ -z "$id" ]; then id="$1"; else usage; exit 1; fi; shift ;;
    esac
  done
  [ -n "$id" ] || die "fail: <task> is required"
  [ -n "$reason" ] || die "fail: --reason <r> is required"
  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  node_exists "$dir" "$id" || die "unknown node: $id"
  node_set "$dir" "$id" 6 failed
  node_set "$dir" "$id" 10 ""
  log_line "$dir" "$id → failed: $reason"
  render_json "$dir"
  printf 'failed=%s\n' "$id"
  printf 'reason=%s\n' "$reason"
}

# The reply half of the node → coordinator channel. Writing the answer clears the
# question in the same call, so a node can never be handed an answer to a gate it
# has already moved past.
cmd_answer() {
  local feature="" id="" answer=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$id" ]; then id="$1"
        elif [ -z "$answer" ]; then answer="$1"
        else usage; exit 1; fi
        shift ;;
    esac
  done
  [ -n "$id" ] || die "answer: <task> is required"
  [ -n "$answer" ] || die "answer: <answer> is required"
  local dir wt scratch
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  node_exists "$dir" "$id" || die "unknown node: $id"
  wt="$(node_field "$dir" "$id" 7)"
  [ -n "$wt" ] && [ -d "$wt" ] || die "answer: $id has no workspace yet"
  scratch="$wt/.context/ship-run/$id"
  [ -f "$scratch/ask.md" ] || die "answer: $id has no pending question"
  printf '%s\n' "$answer" > "$scratch/answer.txt"
  rm -f "$scratch/ask.md"
  # The stall counter has been ticking the whole time the node waited on this, so
  # clear it — otherwise the answer arrives and the cap kills the node anyway.
  rm -f "$dir/stall-$id.txt"
  log_line "$dir" "$id answered: $answer"
  printf 'answered=%s\n' "$id"
  printf 'answer=%s\n' "$answer"
  printf 'note=The node consumes it on its next pipeline.sh next and resumes.\n'
}

reset_usage() {
  echo "usage: graph.sh reset <task>... | --all [--feature <f>]" >&2
  echo "  returns failed node(s) to pending so they can be dispatched again" >&2
}

# `failed` used to be terminal, and a run frozen by it had exactly two ways out:
# abandon it, or hand-edit nodes.tsv — which the graph forbids because it is the
# only writer of its own state. That is the wrong shape for the common case: a
# node is failed most often because the operator STOPPED it (abort marks every
# in-flight node failed), and stopping work is not the same as abandoning it.
# reset is the missing inverse — it puts the node back on the frontier, which
# also unfreezes admission for everything else.
#
# The retry is a FRESH dispatch, not a resume: the worker behind a failed node is
# gone, and the driver contract only ever creates a new workspace. The old one is
# kept on disk and its path recorded in the log before the columns are cleared,
# so whatever partial work it holds is still reachable by hand.
cmd_reset() {
  local feature="" all=0 ids=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --all) all=1; shift ;;
      -h|--help) reset_usage; exit 0 ;;
      -*) reset_usage; exit 1 ;;
      *) ids="$ids $1"; shift ;;
    esac
  done

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"

  if [ "$all" -eq 1 ]; then
    [ -z "${ids# }" ] || die "reset: --all takes no task ids"
    ids="$(nodes_with_status "$dir" failed | tr '\n' ' ')"
    [ -n "${ids# }" ] || die "reset: no failed node to reset"
  fi
  [ -n "${ids# }" ] || { reset_usage; exit 1; }

  # Validate every id before touching anything: a typo in the third of three ids
  # must not leave the graph half-reset.
  local id cur
  for id in $ids; do
    node_exists "$dir" "$id" || die "reset: unknown node: $id"
    cur="$(node_field "$dir" "$id" 6)"
    [ "$cur" = "failed" ] || die "reset: $id is '$cur', not 'failed' — only a failed node can be reset (stop a live one with: graph.sh abort)"
  done

  local n=0 wt
  for id in $ids; do
    wt="$(node_field "$dir" "$id" 7)"
    [ -n "$wt" ] && log_line "$dir" "$id previous workspace kept at $wt"
    node_set "$dir" "$id" 6 pending
    node_set "$dir" "$id" 7 ""
    node_set "$dir" "$id" 8 ""
    node_set "$dir" "$id" 10 ""
    # Stall bookkeeping is per-attempt. Carrying it over would let a node trip
    # the stall cap on its first poll of the new run.
    rm -f "$dir/stall-$id.txt" "$dir/why-$id.txt" "$dir/progress-$id.txt"
    log_line "$dir" "$id failed → pending (reset; attempt $(node_field "$dir" "$id" 9) kept)"
    printf 'reset=%s\n' "$id"
    n=$((n + 1))
  done

  render_json "$dir"
  printf 'count=%s\n' "$n"
  printf 'remaining_failed=%s\n' "$(count_status "$dir" failed)"
  printf 'note=run graph.sh next to dispatch them again — the retry gets a fresh workspace\n'
}

# --- conflicts ---------------------------------------------------------------

cmd_conflicts() {
  local feature=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  local dir base
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  base="$(meta_get "$dir" base_branch)"

  # Real footprint beats declared footprint. If develop touched more than the
  # spec predicted, the neighbour that shares those files must not be admitted —
  # this is the edge that appears by evidence rather than by prediction.
  local id wt real refreshed=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    wt="$(node_field "$dir" "$id" 7)"
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    real="$(git -C "$wt" diff --name-only "$base"...HEAD 2>/dev/null | paste -sd, - || true)"
    [ -n "$real" ] || continue
    node_set "$dir" "$id" 5 "$real"
    log_line "$dir" "$id footprint refreshed from workspace: $real"
    refreshed=$((refreshed + 1))
  done < <(nodes_with_status "$dir" in_flight; nodes_with_status "$dir" landed)

  # A landed node still counts as active: its PR is open, so its files are not
  # on the base yet and a neighbour touching them would be writing against a
  # version of that file the forge is about to replace.
  local active blocked_count=0 cand cand_files act act_files
  active="$( { nodes_with_status "$dir" in_flight; nodes_with_status "$dir" landed; } | sort )"

  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    cand_files="$(node_field "$dir" "$cand" 5)"
    local hit=""
    while IFS= read -r act; do
      [ -n "$act" ] || continue
      act_files="$(node_field "$dir" "$act" 5)"
      if files_overlap "$cand_files" "$act_files"; then hit="$act"; break; fi
    done <<< "$active"
    if [ "$(node_field "$dir" "$cand" 10)" != "$hit" ]; then
      node_set "$dir" "$cand" 10 "$hit"
      [ -n "$hit" ] && log_line "$dir" "$cand blocked_by_conflict=$hit"
    fi
    [ -n "$hit" ] && blocked_count=$((blocked_count + 1))
  done < <(nodes_with_status "$dir" pending; nodes_with_status "$dir" ready)

  render_json "$dir"
  printf 'refreshed=%s\n' "$refreshed"
  printf 'blocked=%s\n' "$blocked_count"
}

# --- iter --------------------------------------------------------------------

cmd_iter() {
  local feature="" name="" max=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --max) max="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *) if [ -z "$name" ]; then name="$1"; else usage; exit 1; fi; shift ;;
    esac
  done
  [ -n "$name" ] || die "iter: <counter-name> is required"
  valid_id "$name" || die "iter: invalid counter name (allowed: [a-zA-Z0-9_-]): $name"
  if [ -n "$max" ]; then
    case "$max" in ''|*[!0-9]*) die "iter: --max must be a positive integer: $max" ;; esac
  fi

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  mkdir -p "$dir"

  local counter_file="$dir/iteration-$name.txt" current=0
  [ -f "$counter_file" ] && current="$(cat "$counter_file")"
  local next=$((current + 1))
  printf '%s\n' "$next" > "$counter_file"

  printf 'count=%s\n' "$next"
  if [ -n "$max" ] && [ "$next" -gt "$max" ]; then
    exit 2
  fi
}

# --- status ------------------------------------------------------------------

abort_usage() {
  echo "usage: graph.sh abort [--feature <f>] [--reason <r>]" >&2
  echo "  stops every in-flight node's worker and marks it failed; workspaces are kept" >&2
  echo "  (a stopped node is not lost: graph.sh reset puts it back on the frontier)" >&2
}

# Killing the orchestrator does NOT stop the workers it dispatched: traps do not
# run on SIGKILL, and once a temporary repo is de-registered the workers vanish
# from the runtime's worktree listing while still running and still billing.
# This is the deliberate way out — stop the agents, record why, keep the
# workspaces so the work can be inspected before anything is thrown away.
cmd_abort() {
  local feature="" reason="aborted by the operator"
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      -h|--help) abort_usage; exit 0 ;;
      *) abort_usage; exit 1 ;;
    esac
  done

  local dir driver
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  driver="$(meta_get "$dir" driver)"

  local id stopped=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    bash "$HOOK_DIR/driver-$driver.sh" stop "$id" --state "$dir" >/dev/null 2>&1 || true
    node_set "$dir" "$id" 6 failed
    log_line "$dir" "$id → failed: $reason (worker stopped)"
    printf 'stopped=%s\n' "$id"
    stopped=$((stopped + 1))
  done < <(nodes_with_status "$dir" in_flight)

  render_json "$dir"
  printf 'aborted=%s\n' "$stopped"
  printf 'note=workspaces kept; run status to see them\n'
}

cmd_status() {
  local feature="" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --json) as_json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"

  if [ "$as_json" -eq 1 ]; then
    cat "$dir/graph.json"
    return 0
  fi

  printf 'feature=%s driver=%s mode=%s base=%s max_in_flight=%s awaiting_merge=%s\n' \
    "$(meta_get "$dir" feature)" "$(meta_get "$dir" driver)" "$(meta_get "$dir" mode)" \
    "$(meta_get "$dir" base_branch)" "$(meta_get "$dir" max_in_flight)" \
    "$(count_status "$dir" landed)"
  printf 'workspaces: %s\n' "$(meta_get "$dir" driver_workspaces)"
  printf '\n%-16s %-10s %-10s %-10s %s\n' "node" "status" "pr" "blocked-by" "deps"
  local sid
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    printf '%-16s %-10s %-10s %-10s %s\n' "$sid" "$(node_field "$dir" "$sid" 6)" \
      "$(pr_status_get "$dir" "$sid" 3)" \
      "$(printf '%s' "$(node_field "$dir" "$sid" 10)" | sed 's/^$/-/')" \
      "$(printf '%s' "$(node_field "$dir" "$sid" 4)" | sed 's/^$/-/')"
  done < <(awk -F'\t' '{ print $1 }' "$dir/nodes.tsv")
}

# --- next --------------------------------------------------------------------

NEXT_BODY=""

next_body_add() {
  NEXT_BODY="${NEXT_BODY}$1
"
}

# `driver`/`workspaces` ride on every emission so the runtime in force is never
# something the operator has to go and ask for. A graph silently running on the
# driver that opens nothing is the failure this whole path exists to prevent;
# printing it each turn is what makes that visible the first time instead of
# hours later.
next_emit() {
  local state="$1" action="$2" inflight="$3" frontier="$4" log="$5"
  printf 'state=%s\naction=%s\ninflight=%s\nfrontier=%s\ndriver=%s\nworkspaces=%s\nlog=%s\ninstruction:\n%s\n' \
    "$state" "$action" "$inflight" "$frontier" "${NEXT_DRIVER:-}" "${NEXT_DRIVER_WORKSPACES:-}" "$log" "$NEXT_BODY"
  exit 0
}

cmd_next() {
  local feature=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"

  # Before anything reads the driver: a graph that fell back once must not stay
  # fallen back forever.
  reelect_driver "$dir"

  local driver max_in_flight log_path
  driver="$(meta_get "$dir" driver)"
  NEXT_DRIVER="$driver"
  NEXT_DRIVER_WORKSPACES="$(meta_get "$dir" driver_workspaces)"
  max_in_flight="$(meta_get "$dir" max_in_flight)"
  log_path="$dir/graph-log.md"

  # An unreadable slot count must not look like a deadlock. Empty is 0 in bash
  # arithmetic, so a meta.tsv missing this key silently yields zero free slots
  # and `next` reports "every remaining node is blocked" over a graph whose
  # nodes are all free — sending the operator hunting for a dependency cycle
  # that does not exist.
  case "$max_in_flight" in
    ''|*[!0-9]*) log_line "$dir" "max_in_flight unreadable ('$max_in_flight') — falling back to 1"; max_in_flight=1 ;;
    *) [ "$max_in_flight" -ge 1 ] || max_in_flight=1 ;;
  esac

  [ -f "$HOOK_DIR/driver-$driver.sh" ] || die "next: meta names driver '$driver' but $HOOK_DIR/driver-$driver.sh does not exist — fix it with: graph.sh set --driver <name>"

  local DRIVER_SH="$HOOK_DIR/driver-$driver.sh"

  local inflight landed failed total merged_n
  inflight="$(count_status "$dir" in_flight)"
  landed="$(count_status "$dir" landed)"
  failed="$(count_status "$dir" failed)"
  merged_n="$(count_status "$dir" merged)"
  total="$(awk 'END { print NR }' "$dir/nodes.tsv")"

  # With no forge to report a merge, a landed node would sit there forever and
  # every dependent behind it with it. Settling those here — not only in `poll` —
  # keeps a run with no remote moving without inventing a merge that never
  # happened: nothing is pushed, nothing is integrated, the node is simply not
  # held behind a signal this environment cannot produce.
  if [ "$landed" -gt 0 ] && ! forge_gate_on "$dir"; then
    settle_landed "$dir" >/dev/null
    landed="$(count_status "$dir" landed)"
    merged_n="$(count_status "$dir" merged)"
  fi

  # --- a failed node freezes admission ---------------------------------------
  if [ "$failed" -gt 0 ] && [ "$inflight" -eq 0 ]; then
    next_body_add "Failed node(s): $(nodes_with_status "$dir" failed | tr '\n' ' ')."
    next_body_add "Report to the user with \`bash \"$HOOK_DIR/graph.sh\" status\` and ask which one: retry them — bash \"$HOOK_DIR/graph.sh\" reset <task>... (or --all), which puts them back on the frontier with a fresh workspace and unfreezes admission — fix by hand and re-run \`bash \"$HOOK_DIR/graph.sh\" next\`, or abandon the run."
    next_emit "ask" "ask" "$inflight" "" "run frozen by failed node(s)"
  fi

  # --- frontier --------------------------------------------------------------
  local slots=$((max_in_flight - inflight))
  local frontier="" cand cand_files picked_files=""
  if [ "$slots" -gt 0 ] && [ "$failed" -eq 0 ]; then
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      [ "$slots" -gt 0 ] || break
      deps_satisfied "$dir" "$cand" || continue
      [ -z "$(node_field "$dir" "$cand" 10)" ] || continue
      cand_files="$(node_field "$dir" "$cand" 5)"
      # Lowest id wins the slot; the loser stays pending with the winner recorded
      # in blocked_by_conflict — a scheduling decision, never an error state.
      if files_overlap "$cand_files" "$picked_files"; then
        node_set "$dir" "$cand" 10 "$(printf '%s' "$frontier" | awk '{print $NF}')"
        continue
      fi
      frontier="$frontier $cand"
      picked_files="$picked_files${picked_files:+,}$cand_files"
      slots=$((slots - 1))
    done < <(nodes_with_status "$dir" pending; nodes_with_status "$dir" ready)
  fi
  frontier="${frontier# }"
  render_json "$dir"

  if [ -n "$frontier" ]; then
    local t repo prompt default_repo
    # A node carries a repo only in multi-repo graphs. Single-repo runs fall back
    # to the graph's own, so a coordinator outside a managed workspace still
    # resolves one instead of leaving the driver to guess from its cwd.
    default_repo="$(meta_get "$dir" repo)"
    for t in $frontier; do
      repo="$(node_field "$dir" "$t" 2)"
      [ -n "$repo" ] || repo="$default_repo"
      prompt="/ship:run $t"
      next_body_add "- bash \"$DRIVER_SH\" dispatch $t \"$prompt\" --state \"$dir\" --base \"$(meta_get "$dir" base_branch)\"${repo:+ --repo \"$repo\"}"
      # Not every driver can start the worker by itself. Some prepare the
      # workspace and hand back an `instruction=` line describing the one step
      # only the caller can take. Leaving that step implicit is how a node gets
      # claimed in_flight with nothing running behind it: the workspace exists,
      # the branch exists, and the graph then waits on a worker that was never
      # started. Making it an ordered, numbered step is the fix.
      next_body_add "- if that dispatch printed an \`instruction=\` line, CARRY IT OUT NOW, before the next call — for this driver that line is what actually starts the worker, and the node is not running until you have"
      # ok=0 means the driver could not observe the worker working. Claiming on
      # that is how a node goes in_flight with an idle agent behind it.
      next_body_add "- if that dispatch printed \`ok=0\`, STOP for this node: do not collect it and do not claim it — report the reason= line to the user"
      next_body_add "- bash \"$DRIVER_SH\" collect $t --state \"$dir\" --base \"$(meta_get "$dir" base_branch)\"   → read worktree= and branch= from its output"
      next_body_add "- bash \"$HOOK_DIR/graph.sh\" claim $t --worktree <worktree> --branch <branch>"
    done
    next_body_add "Dispatch ALL of the above in this turn. Do not start a node the instruction did not list."
    next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/graph.sh\" next — do not evaluate results yourself."
    next_emit "frontier" "dispatch" "$inflight" "$frontier" "$((max_in_flight - inflight)) slot(s) free"
  fi

  # --- questions from the nodes ----------------------------------------------
  # Checked before the stall cap on purpose: a node waiting on an answer makes no
  # phase progress, so it reads as stalled and gets reported as stuck when in
  # fact it asked something and is waiting for this.
  if [ "$inflight" -gt 0 ]; then
    local qid qwt qask asked=""
    while IFS= read -r qid; do
      [ -n "$qid" ] || continue
      qwt="$(node_field "$dir" "$qid" 7)"
      [ -n "$qwt" ] || continue
      qask="$qwt/.context/ship-run/$qid/ask.md"
      [ -f "$qask" ] || continue
      asked="$asked $qid"
      next_body_add "- $qid asks: $(grep -m1 '^question=' "$qask" | sed 's/^question=//') — full text in $qask"
    done < <(nodes_with_status "$dir" in_flight)
    if [ -n "${asked# }" ]; then
      next_body_add "Read each ask.md above and present its question to the user in the artifact language. These come from a node's own pipeline; do not answer them yourself."
      next_body_add "Reply with: bash \"$HOOK_DIR/graph.sh\" answer <task> <answer> — that unblocks the node and it resumes on its next poll."
      next_emit "ask" "ask" "$inflight" "" "node(s) waiting on an answer:${asked}"
    fi
  fi

  # --- wait ------------------------------------------------------------------
  if [ "$inflight" -gt 0 ]; then
    local stalled=""
    local sid
    while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      [ -f "$dir/stall-$sid.txt" ] || continue
      [ "$(cat "$dir/stall-$sid.txt")" -ge 3 ] && stalled="$stalled $sid"
    done < <(nodes_with_status "$dir" in_flight)
    if [ -n "${stalled# }" ]; then
      local never=""
      for sid in $stalled; do
        [ -f "$dir/why-$sid.txt" ] && never="$never $sid"
      done
      if [ -n "${never# }" ]; then
        # Distinguished on purpose: "never started" has a different cause and a
        # different fix from "started and got stuck", and telling the operator to
        # go read a dispatch-log.md that does not exist wastes the one round the
        # stall cap bought.
        next_body_add "Node(s)${never} have NO .context/ship-run/<task>/dispatch-log.md at all — their pipeline never ran a single phase, so the worker was never started. The workspace and branch exist; nothing is running in them."
        next_body_add "The usual cause is the driver's \`instruction=\` line from dispatch not being carried out. Re-issue it: bash \"$DRIVER_SH\" dispatch <task> \"/ship:run <task>\" --state \"$dir\" --base \"$(meta_get "$dir" base_branch)\" and then DO what its instruction= line says."
        next_body_add "If the driver cannot start workers in this environment at all, switch runtimes without losing the run: bash \"$HOOK_DIR/graph.sh\" abort, then bash \"$HOOK_DIR/graph.sh\" set --driver <name>."
        next_emit "ask" "ask" "$inflight" "" "worker never started:${never}"
      fi
      next_body_add "Node(s)${stalled} have shown no phase progress across 3 consecutive polls — their pipeline is stuck or finished without leaving its completion marker."
      next_body_add "Open each one's workspace, read .context/ship-run/<task>/dispatch-log.md to see the last phase it reached, and present that to the user."
      next_body_add "Then either re-drive it (\`bash \"$HOOK_DIR/pipeline.sh\" next <task>\` inside its workspace) or drop it: bash \"$HOOK_DIR/graph.sh\" fail <task> --reason <r>"
      next_emit "ask" "ask" "$inflight" "" "stalled node(s):${stalled}"
    fi
    next_body_add "- bash \"$DRIVER_SH\" wait --state \"$dir\"   → blocks until a worker reports or the wait window closes; a timeout is a checkpoint, not a failure"
    next_body_add "- bash \"$HOOK_DIR/graph.sh\" poll   → lands every node whose pipeline finished and reads the real PR state of the ones already landed. This is the completion signal; do NOT decide it yourself from what a worker said."
    next_body_add "- bash \"$HOOK_DIR/graph.sh\" conflicts"
    next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/graph.sh\" next — do not evaluate results yourself."
    next_emit "wait" "wait" "$inflight" "" "$inflight node(s) in flight"
  fi

  # --- landed: the forge has the ball ----------------------------------------
  # Nothing here merges. Each landed node synced itself onto the base and opened
  # its own PR from the workspace that implemented it; what remains is a human
  # review and a merge on the forge, and the dependents wait on that and not on
  # anything this script could decide.
  if [ "$landed" -gt 0 ]; then
    local lid lstate lurl lnum
    next_body_add "Waiting on the forge. These nodes finished and their PR targets $(meta_get "$dir" base_branch):"
    while IFS= read -r lid; do
      [ -n "$lid" ] || continue
      lstate="$(pr_status_get "$dir" "$lid" 3)"
      lnum="$(pr_status_get "$dir" "$lid" 2)"
      lurl="$(pr_status_get "$dir" "$lid" 4)"
      next_body_add "- $lid — ${lurl:-no PR found for branch $(node_field "$dir" "$lid" 8)} ${lnum:+(#$lnum)} [${lstate:-unknown}]"
    done < <(nodes_with_status "$dir" landed)
    next_body_add "Present them to the user for review and merge, in the artifact language. Ship never merges a PR itself."
    next_body_add "Once one is merged: bash \"$HOOK_DIR/graph.sh\" poll — it reads the real PR state from the forge and releases the dependents. Then bash \"$HOOK_DIR/graph.sh\" next."
    next_body_add "A node whose PR was merged by a route the forge cannot report: bash \"$HOOK_DIR/graph.sh\" complete <task>. One that will not be merged: bash \"$HOOK_DIR/graph.sh\" fail <task> --reason <r>."
    next_emit "landed" "ask" "$inflight" "" "$landed node(s) awaiting merge on the forge"
  fi

  # --- done ------------------------------------------------------------------
  if [ "$merged_n" -eq "$total" ]; then
    next_body_add "Every node's PR is merged into $(meta_get "$dir" base_branch)."
    next_body_add "Present the batch homolog: for each node, its workspace's .context/ship-run/<task>/homolog-report.md (written by the deferred homolog), in the artifact language."
    if ! node_pr_on "$dir"; then
      next_body_add "Then inform: node PRs were off, so each node's branch is still unmerged — run /ship:pr per branch when ready. NEVER auto-invoke /ship:pr."
    fi
    next_emit "done" "done" "0" "" "graph complete — $merged_n/$total nodes"
  fi

  # --- deadlock --------------------------------------------------------------
  next_body_add "No node can advance: nothing in flight, nothing landed, and every remaining node is blocked."
  next_body_add "Run \`bash \"$HOOK_DIR/graph.sh\" status\` and present it — a dependency cycle or a permanent conflict edge needs a human call."
  next_emit "ask" "ask" "0" "" "deadlock — $merged_n/$total nodes merged"
}

# --- dispatch ----------------------------------------------------------------

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  init)      cmd_init "$@" ;;
  set)       cmd_set "$@" ;;
  next)      cmd_next "$@" ;;
  claim)     cmd_claim "$@" ;;
  land)      cmd_land "$@" ;;
  poll)      cmd_poll "$@" ;;
  complete)  cmd_complete "$@" ;;
  fail)      cmd_fail "$@" ;;
  answer)    cmd_answer "$@" ;;
  reset)     cmd_reset "$@" ;;
  abort)     cmd_abort "$@" ;;
  conflicts) cmd_conflicts "$@" ;;
  status)    cmd_status "$@" ;;
  iter)      cmd_iter "$@" ;;
  nodes)     cmd_nodes "$@" ;;
  *)         usage; exit 1 ;;
esac
