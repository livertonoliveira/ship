#!/usr/bin/env bash

# task-merge.sh — which tasks of a spec should be one task.
#
#   task-merge.sh --from <nodes.json> [--max-files N] [--max-lines N]
#   task-merge.sh --tasks <tasks.md>   [--max-files N] [--max-lines N]
#
# Measured on a 27-node graph (2026-10-13): a node costs ~$1.50 whatever its
# size — a 140-line PR $1.49, a 762-line one $2.27 — because the orchestrating
# session, not the code, is the bill. The <400-line ceiling exists so a PR
# stays reviewable in isolation; it was never meant to split one change into
# several. Two tasks are one change when:
#
#   overlap — they declare the same files: at least --min-overlap (default
#             0.5) of the smaller task's files are in the other. They already
#             cannot run in parallel (the graph serializes them on the conflict
#             edge) and the second PR edits what the first just wrote, so the
#             reviewer reads the file twice. One shared hub file (an index, a
#             registry) is not that — a fraction, not a count, keeps hubs from
#             gluing unrelated tasks together.
#   chain   — B's only dependency is A and B is A's only dependent: a straight
#             line nobody else joins, two PRs where one reads as one story.
#
# Both only while the merged task stays reviewable: at most --max-files files
# (default 8) and, when the tasks carry a `lines` estimate, at most --max-lines
# (default 600). A merge that would put a third task both upstream and
# downstream of the group is a cycle and is refused. Same repo only.
#
# Output, one line per proposal: `merge <id>+<id>[+...] reason=<overlap|chain>
# files=<n> [lines=<n>] delays=<n>` — `delays` counts the tasks outside the
# group that would now wait on members they did not depend on (the price of
# the merge in latency) — then `nodes=<n> proposals=<n> after=<n>`. The spec
# applies them (one draft, the union of Files, the union of scenarios, the
# outer Deps); this script only decides, it never rewrites prose. Exit 0 with
# proposals, 1 with none, 2 on bad input.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: task-merge.sh (--from <nodes.json> | --tasks <tasks.md>) [--max-files N] [--max-lines N] [--min-overlap 0.5]" >&2
}

FROM="" TASKS="" MAX_FILES=8 MAX_LINES=600 MIN_OVERLAP=0.5
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --tasks) TASKS="$2"; shift 2 ;;
    --max-files) MAX_FILES="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    --min-overlap) MIN_OVERLAP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
case "$MAX_FILES$MAX_LINES" in *[!0-9]*) usage; exit 2 ;; esac
case "$MIN_OVERLAP" in ''|*[!0-9.]*) usage; exit 2 ;; esac

nodes_json=""
if [ -n "$TASKS" ]; then
  [ -f "$TASKS" ] || { echo "task-merge.sh: no such file: $TASKS" >&2; exit 2; }
  nodes_json="$(bash "$HOOK_DIR/graph.sh" nodes --from-tasks "$TASKS")" || exit 2
elif [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "task-merge.sh: no such file: $FROM" >&2; exit 2; }
  nodes_json="$(cat "$FROM")"
else
  usage; exit 2
fi

# nodes.json is one object per node; the fields are read by name so the order
# of keys and the pretty-printing do not matter. A `lines` number is optional.
printf '%s\n' "$nodes_json" | tr -d '\n' | sed 's/}[[:space:]]*,[[:space:]]*{/}\
{/g' | awk -v MAXF="$MAX_FILES" -v MAXL="$MAX_LINES" -v MINO="$MIN_OVERLAP" '
  function field(s, k,   r) {
    r = ""
    if (match(s, "\"" k "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
      r = substr(s, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*"/, "", r); sub(/"$/, "", r)
    }
    return r
  }
  function list(s, k,   r, n, i, parts, out) {
    out = ""
    if (match(s, "\"" k "\"[[:space:]]*:[[:space:]]*\\[[^]]*\\]")) {
      r = substr(s, RSTART, RLENGTH); sub(/^[^[]*\[/, "", r); sub(/\]$/, "", r)
      n = split(r, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", parts[i])
        if (parts[i] != "") out = out (out == "" ? "" : "\001") parts[i]
      }
    }
    return out
  }
  function num(s, k,   r) {
    if (match(s, "\"" k "\"[[:space:]]*:[[:space:]]*[0-9]+")) {
      r = substr(s, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*/, "", r); return r + 0
    }
    return 0
  }
  function has(set, x) { return index("\001" set "\001", "\001" x "\001") > 0 }
  function union(a, b,   n, i, p, out) {
    out = a
    n = split(b, p, "\001")
    for (i = 1; i <= n; i++) if (p[i] != "" && !has(out, p[i])) out = out (out == "" ? "" : "\001") p[i]
    return out
  }
  function count(set,   p) { return set == "" ? 0 : split(set, p, "\001") }
  function shared(a, b,   n, i, p, c) {
    c = 0
    n = split(a, p, "\001")
    for (i = 1; i <= n; i++) if (p[i] != "" && has(b, p[i])) c++
    return c
  }
  function overlaps(a, b,   s, m) {
    s = shared(a, b)
    if (s == 0) return 0
    m = count(a) < count(b) ? count(a) : count(b)
    return (s / m) >= MINO
  }
  # Tasks outside the group that depend on a member but not on every member:
  # after the merge they wait on work they never needed.
  function delays(r,   x, m, i, n, p, waits, all) {
    all = 0
    for (x in id) {
      if (find(x) == r) continue
      waits = 0; n = 0
      for (i = 1; i <= N; i++) {
        m = order[i]
        if (find(m) != r) continue
        n++
        if (reaches(x, m)) waits++
      }
      if (waits > 0 && waits < n) all++
    }
    return all
  }
  function find(x) { while (parent[x] != x) x = parent[x]; return x }
  # Dependency reachability over nodes, group-aware: does `from` reach `to`?
  function reaches(from, to,   q, head, tail, i, n, p, seen, x) {
    delete seen
    head = 1; tail = 1; q[tail++] = from; seen[from] = 1
    while (head < tail) {
      x = q[head++]
      n = split(deps[x], p, "\001")
      for (i = 1; i <= n; i++) {
        if (p[i] == "") continue
        if (p[i] == to) return 1
        if (!(p[i] in seen)) { seen[p[i]] = 1; q[tail++] = p[i] }
      }
    }
    return 0
  }
  # Would merging the groups of a and b put some outside node both upstream and
  # downstream of the merged group? Then the merge is a cycle.
  function cycle(a, b,   ra, rb, m, i, up, down, x) {
    ra = find(a); rb = find(b)
    for (x in id) {
      if (find(x) == ra || find(x) == rb) continue
      up = 0; down = 0
      for (i = 1; i <= N; i++) {
        m = order[i]
        if (find(m) != ra && find(m) != rb) continue
        if (reaches(m, x)) up = 1
        if (reaches(x, m)) down = 1
      }
      if (up && down) return 1
    }
    return 0
  }
  function direct_only(a, b,   n, i, p, m) {
    # b depends on a and on nothing else; a has no dependent other than b
    if (deps[b] != a) return 0
    for (m in id) if (m != b && has(deps[m], a)) return 0
    return 1
  }
  function try_merge(a, b, why,   ra, rb, f, l) {
    ra = find(a); rb = find(b)
    if (ra == rb) return
    if (repo[a] != repo[b]) return
    f = union(gfiles[ra], gfiles[rb])
    if (count(f) > MAXF) return
    l = glines[ra] + glines[rb]
    if (l > MAXL) return
    if (cycle(a, b)) return
    parent[rb] = ra
    gfiles[ra] = f; glines[ra] = l
    gmembers[ra] = gmembers[ra] "\001" gmembers[rb]
    greason[ra] = (greason[ra] == "" ? why : (greason[ra] == why ? why : greason[ra] "+" why))
  }
  /"id"/ {
    i = field($0, "id"); if (i == "") next
    N++; order[N] = i; id[i] = 1
    repo[i] = field($0, "repo"); deps[i] = list($0, "deps"); files[i] = list($0, "files")
    lines[i] = num($0, "lines")
    parent[i] = i; gfiles[i] = files[i]; glines[i] = lines[i]; gmembers[i] = i; greason[i] = ""
  }
  END {
    if (N == 0) { print "task-merge.sh: no nodes found" > "/dev/stderr"; exit 2 }
    # overlap first — those pairs are serialized anyway — then straight chains,
    # in input order so the result is the same on every run.
    for (i = 1; i <= N; i++) for (j = i + 1; j <= N; j++) {
      a = order[i]; b = order[j]
      if (overlaps(files[a], files[b])) try_merge(a, b, "overlap")
    }
    for (i = 1; i <= N; i++) for (j = 1; j <= N; j++) {
      a = order[i]; b = order[j]
      if (a == b) continue
      if (direct_only(a, b)) try_merge(a, b, "chain")
    }
    groups = 0; proposals = 0
    for (i = 1; i <= N; i++) {
      r = order[i]
      if (find(r) != r) continue
      groups++
      n = split(gmembers[r], p, "\001")
      if (n < 2) continue
      proposals++
      members = ""
      for (k = 1; k <= n; k++) if (p[k] != "") members = members (members == "" ? "" : "+") p[k]
      printf "merge %s reason=%s files=%d", members, greason[r], count(gfiles[r])
      if (glines[r] > 0) printf " lines=%d", glines[r]
      printf " delays=%d\n", delays(r)
    }
    printf "nodes=%d proposals=%d after=%d\n", N, proposals, groups
    exit (proposals > 0 ? 0 : 1)
  }
'
