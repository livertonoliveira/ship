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
# This script never names a workspace runtime. Everything runtime-specific goes
# through driver-<name>.sh's five verbs (dispatch/collect/wait/ask/stop), so swapping
# runtimes is swapping a file. scripts/check-graph-driver-isolation.sh enforces it.
# ---------------------------------------------------------------------------

usage() {
  echo "usage: graph.sh <subcommand> [args...]" >&2
  echo "  init      --feature <f> --from <nodes.json> [--driver <d>] [--max-in-flight N]" >&2
  echo "            [--base-branch <ref>] [--mode linear|local] [--repo <id>] [--fresh]" >&2
  echo "  next      [--feature <f>]" >&2
  echo "  claim     <task> --worktree <path> --branch <ref> [--feature <f>]" >&2
  echo "  land      <task> [--feature <f>]" >&2
  echo "  poll      [--feature <f>] [--stall-max N]" >&2
  echo "  merge     <task> [--feature <f>] [--config <path>]" >&2
  echo "  complete  <task> [--feature <f>]" >&2
  echo "  fail      <task> --reason <r> [--feature <f>]" >&2
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
# status: pending → ready → in_flight → landed → merging → done · terminal: failed

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
      printf '      "blocked_by_conflict": %s\n' "$(json_str_or_null "$blocked")"
      printf '    }'
    done < <(nodes_rows "$dir")
    [ "$first" -eq 1 ] || printf '\n'
    printf '  ],\n'
    printf '  "integration": { "last_merged": %s, "status": "%s" }\n' \
      "$(json_str_or_null "$(meta_get "$dir" integration_last_merged)")" \
      "$(json_escape "$(meta_get "$dir" integration_status)")"
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

deps_satisfied() {
  local dir="$1" id="$2" deps d st
  deps="$(node_field "$dir" "$id" 4)"
  [ -n "$deps" ] || return 0
  local old_ifs="$IFS"
  IFS=','
  for d in $deps; do
    [ -n "$d" ] || continue
    st="$(node_field "$dir" "$d" 6)"
    if [ -z "$st" ] || [ "$st" != "done" ]; then IFS="$old_ifs"; return 1; fi
  done
  IFS="$old_ifs"
  return 0
}

# --- init --------------------------------------------------------------------

# Local mode keeps the spec in ship/changes/<feature>/, and /ship:spec leaves it
# UNCOMMITTED — only /ship:pr ever commits. Every node workspace is branched from
# the base ref, so an uncommitted spec simply is not there: the node's pipeline
# reaches its context state, finds no proposal/design/tasks, and stops.
#
# Sealing it onto the base once, here, is the only placement that works. Copying
# it per node instead would have every node commit the same files and collide at
# merge time.
seal_spec() {
  local dir="$1" feature="$2" spec_dir="ship/changes/$feature"
  [ -d "$spec_dir" ] || return 0
  git add -- "$spec_dir" >/dev/null 2>&1 || return 0
  git diff --cached --quiet -- "$spec_dir" 2>/dev/null && return 0
  git commit -q -m "docs($feature): spec artifacts for the work graph" -- "$spec_dir" >/dev/null 2>&1 || return 0
  log_line "$dir" "spec sealed onto $(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo HEAD) so node workspaces inherit it"
}

cmd_init() {
  local feature="" from="" driver="manual" max_in_flight="2" base_branch="" mode="local" fresh=0 default_repo=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --from) from="$2"; shift 2 ;;
      --driver) driver="$2"; shift 2 ;;
      --max-in-flight) max_in_flight="$2"; shift 2 ;;
      --base-branch) base_branch="$2"; shift 2 ;;
      --mode) mode="$2"; shift 2 ;;
      --repo) default_repo="$2"; shift 2 ;;
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
  valid_id "$driver" || die "init: invalid driver name: $driver"
  [ -f "$HOOK_DIR/driver-$driver.sh" ] || die "init: no driver at $HOOK_DIR/driver-$driver.sh"

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
    printf 'done=%s\n' "$(count_status "$dir" done)"
    exit 3
  fi

  if [ -z "$base_branch" ]; then
    base_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    base_branch="${base_branch:-main}"
  fi

  mkdir -p "$dir"
  [ "$fresh" -eq 1 ] && rm -f "$dir"/iteration-*.txt "$dir/nodes.tsv" "$dir/meta.tsv"

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
  meta_set "$dir" base_branch "$base_branch"
  meta_set "$dir" max_in_flight "$max_in_flight"
  meta_set "$dir" repo "$default_repo"
  meta_set "$dir" integration_status green
  meta_set "$dir" integration_last_merged ""

  mkdir -p "$GRAPH_ROOT"
  printf '%s\n' "$feature" > "$ACTIVE_POINTER"

  render_json "$dir"
  log_line "$dir" "init feature=$feature driver=$driver mode=$mode max_in_flight=$max_in_flight base=$base_branch nodes=$(wc -l < "$dir/nodes.tsv" | tr -d ' ')"
  [ "$mode" = "local" ] && seal_spec "$dir" "$feature"

  printf 'INIT %s\n' "$feature"
  printf 'feature=%s\n' "$feature"
  printf 'graph=%s\n' "$dir/graph.json"
  printf 'nodes=%s\n' "$(wc -l < "$dir/nodes.tsv" | tr -d ' ')"
  printf 'driver=%s\n' "$driver"
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

  # Baseline the progress counter here, not on the first poll. Without it the
  # first poll always reads as progress (no previous value to compare against)
  # and the stall cap silently needs one extra round.
  printf '%s\n' "$(awk 'END { print NR + 0 }' "$scratch/dispatch-log.md" 2>/dev/null || echo 0)" \
    > "$dir/progress-$id.txt"
  rm -f "$dir/stall-$id.txt"

  render_json "$dir"

  printf 'claimed=%s\n' "$id"
  printf 'worktree=%s\n' "$wt"
  printf 'branch=%s\n' "$branch"
  printf 'homolog_mode=defer\n'
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
      rm -f "$dir/progress-$id.txt" "$dir/stall-$id.txt"
      printf 'landed=%s\n' "$id"
      landed=$((landed + 1))
      continue
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
      log_line "$dir" "$id STALLED — no phase progress across $stalls polls"
      printf 'stalled=%s\n' "$id"
      stalled=$((stalled + 1))
    else
      log_line "$dir" "$id quiet ($stalls/$stall_max polls with no phase progress)"
      printf 'quiet=%s\n' "$id"
    fi
  done < <(nodes_with_status "$dir" in_flight)

  render_json "$dir"
  printf 'summary=landed:%s working:%s stalled:%s\n' "$landed" "$working" "$stalled"
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
  transition "$dir" "$id" "merging,landed" done
  meta_set "$dir" integration_last_merged "$id"
  meta_set "$dir" integration_status green
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
  done < <(nodes_with_status "$dir" in_flight; nodes_with_status "$dir" merging)

  local active blocked_count=0 cand cand_files act act_files
  active="$( { nodes_with_status "$dir" in_flight; nodes_with_status "$dir" merging; } | sort )"

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

# --- merge node --------------------------------------------------------------

# The verifier that does not exist inside a single task's pipeline: two nodes
# green in isolation can be red together. Merges one landed branch into the base
# checkout, then re-runs the FULL suite — a synthetic scratch with no
# generated-tests.md is exactly what makes test-exec.sh drop its file scoping.
cmd_merge() {
  local feature="" id="" config="ship/config.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) feature="$2"; shift 2 ;;
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *) if [ -z "$id" ]; then id="$1"; else usage; exit 1; fi; shift ;;
    esac
  done
  [ -n "$id" ] || die "merge: <task> is required"

  local dir
  dir="$(graph_dir "$(resolve_feature "$feature")")"
  require_graph "$dir"
  node_exists "$dir" "$id" || die "unknown node: $id"

  local status branch wt
  status="$(node_field "$dir" "$id" 6)"
  case "$status" in
    landed|merging) ;;
    *) die "merge: $id is '$status' — only a landed node can be merged" ;;
  esac
  branch="$(node_field "$dir" "$id" 8)"
  [ -n "$branch" ] || die "merge: $id has no branch recorded (claim it first)"
  wt="$(node_field "$dir" "$id" 7)"

  [ "$status" = "merging" ] || { transition "$dir" "$id" "landed" merging; render_json "$dir"; }

  # Already an ancestor → this is a re-verification after a merge-fix round, not
  # a second merge. Idempotent by construction.
  if ! git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
    if ! git merge --no-ff --no-edit "$branch" >"$dir/merge-$id.log" 2>&1; then
      meta_set "$dir" integration_status red
      meta_set "$dir" integration_reason "merge conflict on $branch"
      render_json "$dir"
      log_line "$dir" "$id merge conflict — see $dir/merge-$id.log"
      printf 'result=red\n'
      printf 'reason=merge-conflict\n'
      printf 'log=%s\n' "$dir/merge-$id.log"
      exit 1
    fi
  fi

  local ms="$dir/merge/$id"
  mkdir -p "$ms"
  if [ -n "$wt" ] && [ -f "$wt/.context/ship-run/$id/stack.md" ]; then
    cp "$wt/.context/ship-run/$id/stack.md" "$ms/stack.md"
  else
    {
      printf '# Stack\n\n'
      local f v
      for f in Runtime Framework 'Package Manager' 'Test Framework' Typecheck Lint; do
        v="$(grep -m1 -E "^- $f:" "$config" 2>/dev/null | sed -E "s/^- $f:[[:space:]]*//" || true)"
        printf -- '- %s: %s\n' "$f" "${v:-unknown}"
      done
    } > "$ms/stack.md"
  fi
  rm -f "$ms/generated-tests.md" "$ms/static-exec-done.txt"

  local rc=0
  set +e
  bash "$HOOK_DIR/test-exec.sh" "$ms" --config "$config" >"$ms/exec.log" 2>&1
  rc=$?
  set -e

  case "$rc" in
    0|2)
      meta_set "$dir" integration_status green
      meta_set "$dir" integration_reason ""
      transition "$dir" "$id" "merging" done
      meta_set "$dir" integration_last_merged "$id"
      render_json "$dir"
      printf 'result=green\n'
      printf 'completed=%s\n' "$id"
      if [ "$rc" -eq 2 ]; then
        printf 'note=no test runner resolved — merge accepted on the static gate alone\n'
      fi
      ;;
    *)
      meta_set "$dir" integration_status red
      meta_set "$dir" integration_reason "integration suite red after merging $id"
      render_json "$dir"
      log_line "$dir" "$id integration suite red — see $ms/test-failures.md"
      printf 'result=red\n'
      printf 'reason=suite-red\n'
      printf 'failures=%s\n' "$ms/test-failures.md"
      exit 1
      ;;
  esac
}

# --- status ------------------------------------------------------------------

abort_usage() {
  echo "usage: graph.sh abort [--feature <f>] [--reason <r>]" >&2
  echo "  stops every in-flight node's worker and marks it failed; workspaces are kept" >&2
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
  done < <({ nodes_with_status "$dir" in_flight; nodes_with_status "$dir" merging; })

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

  printf 'feature=%s driver=%s mode=%s base=%s max_in_flight=%s integration=%s\n' \
    "$(meta_get "$dir" feature)" "$(meta_get "$dir" driver)" "$(meta_get "$dir" mode)" \
    "$(meta_get "$dir" base_branch)" "$(meta_get "$dir" max_in_flight)" \
    "$(meta_get "$dir" integration_status)"
  printf '\n%-16s %-10s %-10s %s\n' "node" "status" "blocked-by" "deps"
  awk -F'\t' '{ printf "%-16s %-10s %-10s %s\n", $1, $6, ($10 == "" ? "-" : $10), ($4 == "" ? "-" : $4) }' "$dir/nodes.tsv"
}

# --- next --------------------------------------------------------------------

NEXT_BODY=""

next_body_add() {
  NEXT_BODY="${NEXT_BODY}$1
"
}

next_emit() {
  local state="$1" action="$2" inflight="$3" frontier="$4" log="$5"
  printf 'state=%s\naction=%s\ninflight=%s\nfrontier=%s\nlog=%s\ninstruction:\n%s\n' \
    "$state" "$action" "$inflight" "$frontier" "$log" "$NEXT_BODY"
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

  local driver max_in_flight integ log_path
  driver="$(meta_get "$dir" driver)"
  max_in_flight="$(meta_get "$dir" max_in_flight)"
  integ="$(meta_get "$dir" integration_status)"
  log_path="$dir/graph-log.md"

  local DRIVER_SH="$HOOK_DIR/driver-$driver.sh"

  local inflight merging landed failed total done_n
  inflight="$(count_status "$dir" in_flight)"
  merging="$(count_status "$dir" merging)"
  landed="$(count_status "$dir" landed)"
  failed="$(count_status "$dir" failed)"
  done_n="$(count_status "$dir" done)"
  total="$(awk 'END { print NR }' "$dir/nodes.tsv")"

  # --- integration red: fix the merge before anything else -------------------
  if [ "$integ" = "red" ] && [ "$merging" -gt 0 ]; then
    local mid ms rc=0
    mid="$(nodes_with_status "$dir" merging | head -1)"
    ms="$dir/merge/$mid"
    set +e
    ( cmd_iter "$mid-merge-fix" --max 2 --feature "$(meta_get "$dir" feature)" ) >/dev/null
    rc=$?
    set -e
    if [ "$rc" -eq 2 ]; then
      next_body_add "Integration stayed red after 2 fix rounds merging $mid ($(meta_get "$dir" integration_reason))."
      next_body_add "Present $ms/test-failures.md and $dir/merge-$mid.log to the user, then ask: fix by hand and re-run \`bash \"$HOOK_DIR/graph.sh\" merge $mid\`, or abandon with \`bash \"$HOOK_DIR/graph.sh\" fail $mid --reason <r>\`."
      next_emit "ask" "ask" "$inflight" "" "merge-fix cap reached on $mid"
    fi
    next_body_add "- Agent subagent_type=general-purpose (model sonnet), prompt: \"Integration is red after merging $mid into $(meta_get "$dir" base_branch). Read $ms/test-failures.md and $dir/merge-$mid.log and apply the minimal source fixes — no unrelated refactors, no comments, no spec IDs in code. Report what you changed.\""
    next_body_add "- bash \"$HOOK_DIR/graph.sh\" merge $mid"
    next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/graph.sh\" next — do not evaluate results yourself."
    next_emit "merge-fix" "dispatch" "$inflight" "" "integration red on $mid — dispatching fix agent"
  fi

  # --- merge node: serialized, one at a time ---------------------------------
  if [ "$merging" -gt 0 ] || [ "$landed" -gt 0 ]; then
    local mid
    if [ "$merging" -gt 0 ]; then
      mid="$(nodes_with_status "$dir" merging | head -1)"
    else
      mid="$(nodes_with_status "$dir" landed | head -1)"
    fi
    next_body_add "- bash \"$HOOK_DIR/graph.sh\" merge $mid"
    next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/graph.sh\" next — do not evaluate results yourself."
    next_emit "merge" "work" "$inflight" "" "integrating $mid into $(meta_get "$dir" base_branch)"
  fi

  # --- a failed node freezes admission ---------------------------------------
  if [ "$failed" -gt 0 ] && [ "$inflight" -eq 0 ]; then
    next_body_add "Failed node(s): $(nodes_with_status "$dir" failed | tr '\n' ' ')."
    next_body_add "Report to the user with \`bash \"$HOOK_DIR/graph.sh\" status\` and ask whether to abandon the run or fix by hand and re-run \`bash \"$HOOK_DIR/graph.sh\" next\`."
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
      next_body_add "- bash \"$DRIVER_SH\" collect $t --state \"$dir\" --base \"$(meta_get "$dir" base_branch)\"   → read worktree= and branch= from its output"
      next_body_add "- bash \"$HOOK_DIR/graph.sh\" claim $t --worktree <worktree> --branch <branch>"
    done
    next_body_add "Dispatch ALL of the above in this turn. Do not start a node the instruction did not list."
    next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/graph.sh\" next — do not evaluate results yourself."
    next_emit "frontier" "dispatch" "$inflight" "$frontier" "$((max_in_flight - inflight)) slot(s) free"
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
      next_body_add "Node(s)${stalled} have shown no phase progress across 3 consecutive polls — their pipeline is stuck, finished without leaving its completion marker, or the workspace never received its prompt."
      next_body_add "Open each one's workspace, read .context/ship-run/<task>/dispatch-log.md to see the last phase it reached, and present that to the user."
      next_body_add "Then either re-drive it (\`bash \"$HOOK_DIR/pipeline.sh\" next <task>\` inside its workspace) or drop it: bash \"$HOOK_DIR/graph.sh\" fail <task> --reason <r>"
      next_emit "ask" "ask" "$inflight" "" "stalled node(s):${stalled}"
    fi
    next_body_add "- bash \"$DRIVER_SH\" wait --state \"$dir\"   → blocks until a worker reports or the wait window closes; a timeout is a checkpoint, not a failure"
    next_body_add "- bash \"$HOOK_DIR/graph.sh\" poll   → lands every node whose pipeline finished. This is the completion signal; do NOT decide it yourself from what a worker said."
    next_body_add "- bash \"$HOOK_DIR/graph.sh\" conflicts"
    next_body_add "After every listed call returns, run: bash \"$HOOK_DIR/graph.sh\" next — do not evaluate results yourself."
    next_emit "wait" "wait" "$inflight" "" "$inflight node(s) in flight"
  fi

  # --- done ------------------------------------------------------------------
  if [ "$done_n" -eq "$total" ]; then
    next_body_add "Every node is integrated into $(meta_get "$dir" base_branch)."
    next_body_add "Present the batch homolog: for each node, its workspace's .context/ship-run/<task>/homolog-report.md (written by the deferred homolog), in the artifact language."
    next_body_add "Then inform: run /ship:pr when ready. NEVER auto-invoke /ship:pr."
    next_emit "done" "done" "0" "" "graph complete — $done_n/$total nodes"
  fi

  # --- deadlock --------------------------------------------------------------
  next_body_add "No node can advance: nothing in flight, nothing landed, and every remaining node is blocked."
  next_body_add "Run \`bash \"$HOOK_DIR/graph.sh\" status\` and present it — a dependency cycle or a permanent conflict edge needs a human call."
  next_emit "ask" "ask" "0" "" "deadlock — $done_n/$total nodes done"
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
  next)      cmd_next "$@" ;;
  claim)     cmd_claim "$@" ;;
  land)      cmd_land "$@" ;;
  poll)      cmd_poll "$@" ;;
  merge)     cmd_merge "$@" ;;
  complete)  cmd_complete "$@" ;;
  fail)      cmd_fail "$@" ;;
  abort)     cmd_abort "$@" ;;
  conflicts) cmd_conflicts "$@" ;;
  status)    cmd_status "$@" ;;
  iter)      cmd_iter "$@" ;;
  nodes)     cmd_nodes "$@" ;;
  *)         usage; exit 1 ;;
esac
