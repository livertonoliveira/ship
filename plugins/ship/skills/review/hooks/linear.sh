#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# linear.sh — the pipeline's Linear round trips, done by a script instead of
# the orchestrator's turns.
#
# Measured on 677 platform-agendx nodes: about 12 of a node's ~46 tool calls
# were Linear MCP calls made one per turn (resolve the status, set it, read the
# issue back, list and fetch the project documents), each turn
# re-reading ~110k tokens of context, and every answer staying in that context
# to the end of the run. Each subcommand below is one tool call.
#
#   linear.sh context    <issue> --out <dir> [--docs <dir>]
#       Writes <dir>/issue.md, plus proposal.md and design.md (every project
#       document whose title starts with Proposal / Design, parts in title
#       order) into --docs (default <dir>). A --docs dir that already holds
#       both files is reused, not fetched again. Other documents go to
#       <docs>/other/<n>.md. Prints the files it wrote.
#   linear.sh transition <issue> started|completed [--prefer <state name>]
#       Moves the issue to the team's state of that type (the --prefer name
#       first, when the team has it) and checks the type Linear reports back.
#
# Exit 4 = LINEAR_API_KEY is unset: the caller falls back to the Linear MCP.
# No jq/python/node: hooks stay runnable anywhere bash and awk are.
# ---------------------------------------------------------------------------

LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

die() { echo "linear.sh: $*" >&2; exit 1; }

usage() {
  echo "usage: linear.sh context <issue> --out <dir> [--docs <dir>]" >&2
  echo "       linear.sh transition <issue> started|completed [--prefer <state name>]" >&2
}

require_key() {
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    echo "linear.sh: LINEAR_API_KEY is not set — use the Linear MCP instead" >&2
    exit 4
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required"
}

valid_issue() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) die "invalid issue identifier: '$1'" ;;
  esac
}

# A string as a JSON literal, quotes included.
json_str() {
  awk 'BEGIN { RS = "\001"; ORS = "" }
    {
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      gsub(/\n/, "\\n"); gsub(/[\001-\037]/, "")
      printf "\"%s\"", $0
    }' <<< "$1" | sed 's/\\n"$/"/'
}

# POST $1 (a JSON body file) and leave the answer in $2. A GraphQL error is a
# failure, whatever the HTTP status said.
gql() {
  local body="$1" out="$2" msg
  printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" \
    | curl -sS --max-time 60 -K - -H 'Content-Type: application/json' \
        --data @"$body" "$LINEAR_API_URL" > "$out" \
    || die "the request to Linear failed"
  if grep -q '"errors"[[:space:]]*:' "$out"; then
    msg="$(flat < "$out" | awk -F '\t' '$1 == "errors.message" { print $2; exit }')"
    die "Linear refused the request: ${msg:-$(head -c 300 "$out")}"
  fi
}

# JSON → one `path<TAB>value` line per scalar. Array elements share their
# array's path; newlines inside a value come out as \001, tabs as \003. Records split on the
# double quote, the same linear scan graph.sh uses on multi-megabyte pages.
flat() {
  awk '
    function unescape(s) {
      gsub(/\\\\/, "\002", s)
      gsub(/\\n/, "\001", s)
      gsub(/\\t/, "\003", s)
      gsub(/\\[rbf]/, "", s)
      gsub(/\\"/, "\"", s)
      gsub(/\\\//, "/", s)
      gsub(/\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/, "?", s)
      gsub("\002", "\\", s)
      return s
    }
    function child(   p) {
      if (depth == 0) return ""
      if (ctype[depth] == "A") return cpath[depth]
      p = cpath[depth]
      return (p == "" ? key : p "." key)
    }
    function open(t,   p) {
      p = child(); depth++
      ctype[depth] = t; cpath[depth] = p; wantkey[depth] = (t == "O")
      if (t == "O") printf "%s\t{\n", p
    }
    function close_() { depth-- }
    function scalar(v) { printf "%s\t%s\n", child(), v }
    function literal() { if (lit != "") { scalar(lit); lit = "" } }
    function outside(s,   i, n, c) {
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]]/) continue
        if (c == "{") open("O")
        else if (c == "[") open("A")
        else if (c == "}" || c == "]") { literal(); close_() }
        else if (c == ":") wantkey[depth] = 0
        else if (c == ",") { literal(); if (ctype[depth] == "O") wantkey[depth] = 1 }
        else lit = lit c
      }
    }
    BEGIN { RS = "\""; instr = 0; depth = 0 }
    !instr { outside($0); instr = 1; next }
    {
      str = str $0
      if (match($0, /\\+$/) && RLENGTH % 2 == 1) { str = str "\""; next }
      if (ctype[depth] == "O" && wantkey[depth]) key = str
      else scalar(unescape(str))
      str = ""; instr = 0
    }
  '
}

cmd_context() {
  local issue="${1:-}" out="" docs=""
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --docs) docs="$2"; shift 2 ;;
      *) usage; exit 1 ;;
    esac
  done
  valid_issue "$issue"
  [ -n "$out" ] || die "context: --out <dir> is required"
  [ -n "$docs" ] || docs="$out"
  require_key
  mkdir -p "$out" "$docs"

  local want_docs=1
  [ -s "$docs/proposal.md" ] && [ -s "$docs/design.md" ] && want_docs=0

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  local q='query($i:String!){issue(id:$i){identifier title description url state{name type} project{name'
  if [ "$want_docs" = 1 ]; then
    q="$q documents(first:100){nodes{title content}}"
  fi
  q="$q}}}"
  printf '{"query":%s,"variables":{"i":%s}}' "$(json_str "$q")" "$(json_str "$issue")" > "$tmp/body.json"
  gql "$tmp/body.json" "$tmp/answer.json"
  flat < "$tmp/answer.json" > "$tmp/flat.tsv"
  grep -q '^data.issue.identifier	' "$tmp/flat.tsv" || die "context: no issue $issue in Linear"

  awk -F '\t' -v out="$out/issue.md" '
    function v(s) { gsub("\001", "\n", s); gsub("\003", "\t", s); return s }
    $1 == "data.issue.identifier" { id = $2 }
    $1 == "data.issue.title" { title = v($2) }
    $1 == "data.issue.description" { desc = v($2) }
    $1 == "data.issue.url" { url = $2 }
    $1 == "data.issue.state.name" { state = $2 }
    $1 == "data.issue.project.name" { project = v($2) }
    END {
      printf "# %s — %s\n\n", id, title > out
      printf "- State: %s\n- Project: %s\n- URL: %s\n\n", state, project, url > out
      print desc > out
    }' "$tmp/flat.tsv"
  echo "issue=$out/issue.md"

  [ "$want_docs" = 1 ] || { echo "docs=$docs (cached)"; return 0; }

  # One record per document, title first; parts are ordered by their title so
  # "Design", "Design (parte 2)"... concatenate in reading order.
  awk -F '\t' -v dir="$tmp/docs" '
    BEGIN { system("mkdir -p \"" dir "\"") }
    $1 == "data.issue.project.documents.nodes" && $2 == "{" { n++; next }
    $1 == "data.issue.project.documents.nodes.title" { t = $2; gsub(/[\/\001]/, " ", t); print t > (dir "/" n ".title"); close(dir "/" n ".title") }
    $1 == "data.issue.project.documents.nodes.content" { c = $2; gsub("\001", "\n", c); gsub("\003", "\t", c); printf "%s\n", c > (dir "/" n ".md"); close(dir "/" n ".md") }
  ' "$tmp/flat.tsv"

  : > "$tmp/proposal.md"; : > "$tmp/design.md"
  local f n title kind others=0
  for f in "$tmp"/docs/*.title; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .title)"
    printf '%s\t%s\n' "$(cat "$f")" "$n"
  done | LC_ALL=C sort > "$tmp/order.tsv"
  while IFS="$(printf '\t')" read -r title n; do
    case "$title" in
      Proposal*) kind=proposal ;;
      Design*) kind=design ;;
      *) kind="" ;;
    esac
    if [ -n "$kind" ]; then
      { printf '<!-- %s -->\n' "$title"; cat "$tmp/docs/$n.md" 2>/dev/null || true; printf '\n'; } >> "$tmp/$kind.md"
    else
      others=$((others + 1))
      mkdir -p "$docs/other"
      { printf '# %s\n\n' "$title"; cat "$tmp/docs/$n.md" 2>/dev/null || true; } > "$docs/other/$others.md"
      echo "other=$docs/other/$others.md ($title)"
    fi
  done < "$tmp/order.tsv"
  for kind in proposal design; do
    if [ -s "$tmp/$kind.md" ]; then
      cp "$tmp/$kind.md" "$docs/$kind.md"
      echo "$kind=$docs/$kind.md"
    else
      echo "$kind=none (no project document titled like it)"
    fi
  done
}

cmd_transition() {
  local issue="${1:-}" type="${2:-}" prefer=""
  [ $# -ge 2 ] && shift 2 || { usage; exit 1; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefer) prefer="$2"; shift 2 ;;
      *) usage; exit 1 ;;
    esac
  done
  valid_issue "$issue"
  case "$type" in started|completed) ;; *) die "transition: type must be started or completed: '$type'" ;; esac
  require_key

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  local q='query($i:String!){issue(id:$i){id state{type} team{states{nodes{id name type}}}}}'
  printf '{"query":%s,"variables":{"i":%s}}' "$(json_str "$q")" "$(json_str "$issue")" > "$tmp/body.json"
  gql "$tmp/body.json" "$tmp/answer.json"
  flat < "$tmp/answer.json" > "$tmp/flat.tsv"

  local uuid state_id state_name
  uuid="$(awk -F '\t' '$1 == "data.issue.id" { print $2; exit }' "$tmp/flat.tsv")"
  [ -n "$uuid" ] || die "transition: no issue $issue in Linear"
  # The configured name wins when the team has a state of that type by that
  # name; otherwise the first state of the type. A name alone can silently
  # no-op after a rename, which is why the state is set by id.
  IFS="$(printf '\t')" read -r state_id state_name < <(awk -F '\t' -v want="$type" -v prefer="$prefer" '
    $1 == "data.issue.team.states.nodes" && $2 == "{" { flush(); id = ""; name = ""; t = ""; next }
    $1 == "data.issue.team.states.nodes.id" { id = $2 }
    $1 == "data.issue.team.states.nodes.name" { name = $2 }
    $1 == "data.issue.team.states.nodes.type" { t = $2 }
    function flush() {
      if (t != want || id == "") return
      if (first == "") first = id "\t" name
      if (prefer != "" && tolower(name) == tolower(prefer) && best == "") best = id "\t" name
    }
    END { flush(); if (best != "") print best; else if (first != "") print first }
  ' "$tmp/flat.tsv") || true
  [ -n "${state_id:-}" ] || die "transition: the team of $issue has no state of type $type"

  local m='mutation($i:String!,$s:String!){issueUpdate(id:$i,input:{stateId:$s}){success issue{state{name type}}}}'
  printf '{"query":%s,"variables":{"i":%s,"s":%s}}' "$(json_str "$m")" "$(json_str "$uuid")" "$(json_str "$state_id")" > "$tmp/body.json"
  gql "$tmp/body.json" "$tmp/answer.json"
  local got
  got="$(flat < "$tmp/answer.json" | awk -F '\t' '$1 == "data.issueUpdate.issue.state.type" { print $2; exit }')"
  [ "$got" = "$type" ] || die "transition: Linear reports $issue as '${got:-unknown}', not $type — check the status names in ship/config.md"
  echo "ok=1"
  echo "issue=$issue"
  echo "state=$state_name"
  echo "type=$got"
}

[ $# -ge 1 ] || { usage; exit 1; }
sub="$1"; shift
case "$sub" in
  context) cmd_context "$@" ;;
  transition) cmd_transition "$@" ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
