#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lib.sh — sourced by every hook script, right after its `set -e…` line:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It carries what used to be re-invented per script, each of which caused a
# bug that cost a run:
#
#   1. A death is never silent. Under `set -e` a failing command ends the
#      script with nothing on either stream (a grep that matched nothing inside
#      an assignment was enough). The ERR trap below names the script, the line
#      and the command (its first line) on stderr before the shell goes.
#
#   2. One JSON reader. json_find / json_get / json_find_all / json_count /
#      json_first_like / json_stream all run the same tokenizer, which knows
#      what a string is — a brace, a quote or a key-shaped text inside a value
#      can no longer end a match early or be mistaken for a key.
#
#   3. One reader for a spec's `## Files` map (spec_file_rows), which the plan
#      scaffold, the plan validator and the pipeline used to parse separately.
#
# Nothing here prints on stdout unless a function is called, and nothing here
# changes a script's exit code.
# ---------------------------------------------------------------------------

# No subshell here: this file is sourced by hooks that run on every tool call.
SHIP_SCRIPT_NAME="${SHIP_SCRIPT_NAME:-${0##*/}}"
case "${BASH_SOURCE[0]}" in
  /*) SHIP_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  */*) SHIP_LIB_DIR="$PWD/${BASH_SOURCE[0]%/*}" ;;
  *) SHIP_LIB_DIR="$PWD" ;;
esac

# Only the shell that is about to exit reports. A command substitution clears
# errexit, so a failure in there is the parent's to judge (it may sit behind
# `|| true`); a region under `set +e` tolerates failures on purpose; and a
# function that ends in `return 1` is handing back a verdict, not crashing.
ship_died() {
  local rc="$1" line="$2" cmd="$3"
  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
  case "$-" in *e*) ;; *) return 0 ;; esac
  case "$cmd" in return|return\ *) return 0 ;; esac
  cmd="${cmd%%$'\n'*}"
  printf '%s: stopped by a failing command at line %s (exit %s): %s\n' "$SHIP_SCRIPT_NAME" "$line" "$rc" "${cmd:0:200}" >&2
}

set -E
trap 'ship_died "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# JSON
#
# Every function reads the document from stdin, or from the file named last.
#
#   json_find <key> [file]          first non-null scalar stored under <key>, at any depth;
#                                   a dotted key (delivery.id) is a path suffix: "id" inside a "delivery"
#   json_find_all <key> [file]      every such value, one per line, in document order
#   json_get <path> [file]          the scalar at an exact path: .a.b[0].c
#   json_count <key> <value> [file] how many times <key> holds exactly <value>
#   json_first_like <ere> [file]    first string value matching the regex (whole value, anchor it yourself)
#   json_stream [file]              one line per scalar: path<TAB>type<TAB>value
#                                   type: s (string) or l (number, true, false, null);
#                                   an object or array announces itself first, as type o or a
#                                   with no value, so an empty one is still seen;
#                                   in the value, \\ \n \t \r stand for those four characters
#   json_stream_flat [file]         the same lines for a reader that wants one value per column:
#                                   a newline, tab or CR in a value is a space, a backslash is itself
#
# Strings come back decoded (\n is a newline, \" is a quote, \uXXXX is UTF-8,
# surrogate pairs included). A key that is missing prints nothing and still
# exits 0: an absent value is an answer, not a failure. The tokenizer runs under
# LC_ALL=C: it only ever cuts at ASCII, so UTF-8 passes through byte for byte.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2016
SHIP_JSON_AWK='
function hexval(h,   i, c, v) {
  v = 0
  for (i = 1; i <= length(h); i++) {
    c = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (c == 0) return -1
    v = v * 16 + c - 1
  }
  return v
}
function utf8(c) {
  if (c < 128) return sprintf("%c", c)
  if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
  if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
  return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64, 128 + int(c / 64) % 64, 128 + c % 64)
}
function decode(s,   n, seg, j, out, c, rest, code, low) {
  if (index(s, "\\") == 0) return s
  n = split(s, seg, /\\/)
  out = seg[1]
  for (j = 2; j <= n; j++) {
    if (seg[j] == "") {
      out = out "\\"
      j++
      if (j <= n) out = out seg[j]
      continue
    }
    c = substr(seg[j], 1, 1)
    rest = substr(seg[j], 2)
    if (c == "n") out = out "\n" rest
    else if (c == "t") out = out "\t" rest
    else if (c == "r") out = out "\r" rest
    else if (c == "b") out = out "\b" rest
    else if (c == "f") out = out "\f" rest
    else if (c == "u") {
      code = hexval(substr(rest, 1, 4))
      if (length(rest) < 4 || code <= 0) { out = out "\\u" rest; continue }
      rest = substr(rest, 5)
      if (code >= 55296 && code <= 56319 && rest == "" && j < n && substr(seg[j + 1], 1, 1) == "u") {
        low = hexval(substr(seg[j + 1], 2, 4))
        if (low >= 56320 && low <= 57343) {
          code = 65536 + (code - 55296) * 1024 + (low - 56320)
          j++
          rest = substr(seg[j], 6)
        }
      }
      out = out utf8(code) rest
    }
    else out = out c rest
  }
  return out
}
function encode(s) {
  gsub(/\\/, "\\\\", s); gsub(/\n/, "\\n", s); gsub(/\t/, "\\t", s); gsub(/\r/, "\\r", s)
  return s
}
function curpath() {
  if (d == 0) return ""
  if (ctype[d] == "o") return base[d] "." key[d]
  return base[d] "[" idx[d] "]"
}
function under(k,   p, want) {
  if (d == 0 || ctype[d] != "o") return 0
  if (index(arg, ".") == 0) return k == arg
  p = curpath(); want = "." arg
  return length(p) >= length(want) && substr(p, length(p) - length(want) + 1) == want
}
function scalar(type, raw,   val, k) {
  val = (type == "s") ? decode(raw) : raw
  k = (d > 0 && ctype[d] == "o") ? key[d] : ""
  if (mode == "stream") { print curpath() "\t" type "\t" encode(val); return }
  if (mode == "flat") { gsub(/[\n\t\r]/, " ", val); print curpath() "\t" type "\t" val; return }
  if (type == "l" && val == "null") { if (mode == "get" && curpath() == arg) finish(); return }
  if (mode == "find" && under(k)) { print val; finish() }
  if (mode == "all" && under(k)) print val
  if (mode == "get" && curpath() == arg) { print val; finish() }
  if (mode == "count" && under(k) && val == arg2) hits++
  if (mode == "like" && type == "s" && val ~ arg) { print val; finish() }
}
function finish() { exit }
function jopen(type,   p) {
  p = curpath()
  if (mode == "stream" || mode == "flat") print p "\t" type "\t"
  d++
  base[d] = p; ctype[d] = type; idx[d] = 0; key[d] = ""; wantkey[d] = 1
}
function jflush() {
  if (lit != "") { scalar("l", lit); lit = "" }
}
function outside(s,   i, n, c) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "{") { jflush(); jopen("o") }
    else if (c == "[") { jflush(); jopen("a") }
    else if (c == "}" || c == "]") { jflush(); if (d > 0) d-- }
    else if (c == ":") { jflush(); if (d > 0) wantkey[d] = 0 }
    else if (c == ",") { jflush(); if (d > 0) { if (ctype[d] == "a") idx[d]++; else wantkey[d] = 1 } }
    else if (c == " " || c == "\t" || c == "\n" || c == "\r") jflush()
    else lit = lit c
  }
  jflush()
}
function token(s) {
  if (d > 0 && ctype[d] == "o" && wantkey[d]) key[d] = decode(s)
  else scalar("s", s)
}
# Records are split on the double quote, so every other record is a string and
# the scan stays linear on a multi-megabyte document.
BEGIN {
  RS = "\""
  mode = ENVIRON["SHIP_JSON_MODE"]; arg = ENVIRON["SHIP_JSON_ARG"]; arg2 = ENVIRON["SHIP_JSON_ARG2"]
  d = 0; lit = ""; hits = 0; instr = 0; str = ""
}
!instr { outside($0); instr = 1; next }
{
  str = str $0
  if (match($0, /\\+$/) && RLENGTH % 2 == 1) { str = str "\""; next }
  token(str)
  str = ""; instr = 0
}
END { if (mode == "count") print hits }
'

ship_json() {
  local mode="$1" arg="${2:-}" arg2="${3:-}" file="${4:-}"
  if [ -n "$file" ]; then
    LC_ALL=C SHIP_JSON_MODE="$mode" SHIP_JSON_ARG="$arg" SHIP_JSON_ARG2="$arg2" awk "$SHIP_JSON_AWK" "$file"
  else
    LC_ALL=C SHIP_JSON_MODE="$mode" SHIP_JSON_ARG="$arg" SHIP_JSON_ARG2="$arg2" awk "$SHIP_JSON_AWK"
  fi
}

json_find()       { ship_json find "$1" "" "${2:-}"; }
json_find_all()   { ship_json all "$1" "" "${2:-}"; }
json_get()        { ship_json get "$1" "" "${2:-}"; }
json_count()      { ship_json count "$1" "$2" "${3:-}"; }
json_first_like() { ship_json like "$1" "" "${2:-}"; }
json_stream()     { ship_json stream "" "" "${1:-}"; }
json_stream_flat() { ship_json flat "" "" "${1:-}"; }

# nodes.json — an array of objects whose values are strings, string arrays,
# numbers or null — as one TSV row per node, in document order:
#   id  repo  title  deps  files  lines        (deps/files comma-joined)
# Read by name, so neither the key order nor the pretty-printing matters; a
# value nested deeper than the node itself is not the node's.
nodes_json_rows() {
  json_stream_flat "${1:-}" | awk -F'\t' '
    {
      p = $1
      if ($2 == "o" || $2 == "a") next
      if (p ~ /^\[[0-9]+\]\./) { rec = p; sub(/\].*/, "", rec); rest = p; sub(/^\[[0-9]+\]\./, "", rest) }
      else if (p ~ /^\./) { rec = "["; rest = substr(p, 2) }
      else next
      if (!(rec in seen)) { seen[rec] = 1; order[++n] = rec }
      v = ($2 == "l" && $3 == "null") ? "" : $3
      if (rest ~ /^(deps|files)\[[0-9]+\]$/) {
        k = rest; sub(/\[.*/, "", k)
        if (v != "") { cur = list[rec, k]; list[rec, k] = (cur == "" ? v : cur "," v) }
      } else if (rest == "id" || rest == "repo" || rest == "title" || rest == "deps" || rest == "files" || rest == "lines") {
        field[rec, rest] = v
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        r = order[i]
        deps = (list[r, "deps"] != "") ? list[r, "deps"] : field[r, "deps"]
        files = (list[r, "files"] != "") ? list[r, "files"] : field[r, "files"]
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", field[r, "id"], field[r, "repo"], field[r, "title"], deps, files, field[r, "lines"]
      }
    }
  '
}

# ---------------------------------------------------------------------------
# Spec
#
#   spec_file_rows <spec.md>        the `## Files` entries the spec owns, as
#                                   verb<TAB>path (verb: create or modify), sorted, no repeats
#
# "create|modify `<path>` — <intent>", with or without a leading bullet. Both
# shapes occur in practice — the local-mode fixture writes the dash, a real
# Linear-mode spec does not, and Linear rewrites "- " as "* " (measured
# 2026-10-06: 192 of 203 graph nodes got an empty inventory that way). The
# heading level is not fixed either: a slice that nested it as `### Files`
# scaffolded an empty inventory and the plan was checked against nothing.
# `Âncora:` lines are pattern references, not owned files. Never fails on spec
# content: a spec with no map prints nothing.
# ---------------------------------------------------------------------------
spec_file_rows() {
  local spec="$1"
  [ -f "$spec" ] || return 0
  bash "$SHIP_LIB_DIR/files-expand.sh" "$spec" | awk '
    /^##+[[:space:]]+Files([^[:alnum:]_]|$)/ { insection = 1; next }
    /^#+[[:space:]]/ { insection = 0 }
    insection && /^[[:space:]]*([-*][[:space:]]*)?(create|modify|Âncora|Ancora|Anchor)/ {
      line = $0
      sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
      gsub(/`/, "", line)
      if (line ~ /^(Âncora|Ancora|Anchor)[[:space:]]*:/) next
      if (!match(line, /^(create|modify)[[:space:]]+/)) next
      verb = substr(line, 1, RLENGTH - 1)
      sub(/[[:space:]]+$/, "", verb)
      sub(/^(create|modify)[[:space:]]+/, "", line)
      # A multi-repo spec names the repo before the path ("platform-agendx:
      # src/a.ts"), and Linear escapes markdown in what it stores ("hooks/\*.ts").
      # The prefix is a repo only when a path follows it: "README.md: note"
      # names the file, and the colon opens its note.
      if (match(line, /^[A-Za-z0-9._-]+:[[:space:]]+/)) {
        rest = substr(line, RLENGTH + 1)
        first = rest
        sub(/[[:space:]].*$/, "", first)
        sub(/[,;:]+$/, "", first)
        if (first ~ /\// || first ~ /\.[A-Za-z0-9]+$/) line = rest
      }
      gsub(/\\/, "", line)
      sub(/[[:space:]]*(—|–|--).*$/, "", line)
      # A colon separates the note as the dash does ("src/a.ts: adds X").
      # Measured live on platform-agendx (2026-11-15): carried into the path,
      # "src/a.ts:" named a file no module could claim and failed the node.
      sub(/:[[:space:]].*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      # The path is the first word: whatever follows it before the dash is a
      # note ("src/a.ts (localizar)"), and carried along it names a file no
      # module can claim (MOB-7233 failed plan validation twice, 2026-10-08).
      # One entry may list several files ("modify a.ts, b.ts — note"): split
      # on commas, and a trailing comma is never part of a path — MOB-8123
      # failed plan validation twice on "services-section.tsx,", 2026-10-15.
      n = split(line, parts, /[[:space:]]*,[[:space:]]*/)
      for (pi = 1; pi <= n; pi++) {
        item = parts[pi]
        sub(/[[:space:]].*$/, "", item)
        sub(/[,;:]+$/, "", item)
        if (item == "") continue
        if (item !~ /\// && item !~ /\.[A-Za-z0-9]+$/) continue
        emit[++ne] = item
      }
      if (ne == 0) next
      for (pi = 1; pi <= ne; pi++) print verb "\t" emit[pi]
      ne = 0; delete emit
    }
  ' 2>/dev/null | sort -u || true
}
