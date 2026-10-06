#!/usr/bin/env bash

# coverage-correlate.sh --items <file> [--layers unit,integration,e2e] [--out <file>]
#
# The arithmetic half of the test-coverage audit. The agent discovers the spec
# items (REQ/AC/SC) and writes, per item, English keywords in the codebase's
# vocabulary — the spec may be written in another language, and bridging that
# is judgment. Everything after that is deterministic and lives here: find the
# test files, extract test names, classify each by layer, tokenize, score every
# item against every test of its layer with Jaccard similarity, and band it.
#
# Items file: one item per line, tab-separated
#   <id> <TAB> <layer | -> <TAB> <english keywords>
# `-` (REQ/AC) is scored against every enabled layer and reported at its best
# one — an AC covered by a unit test is covered; a scenario carries its own
# `@layer` and is scored against that layer only.
#
# Bands: >= 0.5 covered · 0.3-0.49 uncertain · < 0.3 uncovered.
# Findings: 0.0 → high · uncertain → medium · anything else → none.

set -euo pipefail

ITEMS=""
LAYERS="unit,integration,e2e"
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --items) ITEMS="$2"; shift 2 ;;
    --layers) LAYERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help)
      echo "usage: coverage-correlate.sh --items <file> [--layers unit,integration,e2e] [--out <file>]" >&2
      exit 0 ;;
    *) echo "coverage-correlate.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$ITEMS" ] || { echo "coverage-correlate.sh: --items is required" >&2; exit 1; }
[ -f "$ITEMS" ] || { echo "coverage-correlate.sh: items file not found: $ITEMS" >&2; exit 1; }
case ",$LAYERS," in
  *,unit,*|*,integration,*|*,e2e,*) ;;
  *) echo "coverage-correlate.sh: --layers must name at least one of unit,integration,e2e" >&2; exit 1 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "coverage-correlate.sh: not inside a git work tree" >&2
  exit 1
fi

TESTS="$(mktemp)"
trap 'rm -f "$TESTS" "$TESTS".*' EXIT

# camelCase / snake_case / kebab-case / punctuation → space-separated lower-case words.
normalize() {
  sed -E 's/([a-z0-9])([A-Z])/\1 \2/g; s/([A-Z]+)([A-Z][a-z])/\1 \2/g' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g'
}

git ls-files 2>/dev/null \
  | grep -vE '(^|/)(node_modules|vendor|dist|build|out|target|coverage)(/|$)' \
  | grep -E '(^|/)(test|tests|__tests__|spec|e2e|integration)/|\.(test|spec)\.[a-z]+$|_test\.(go|py)$|(^|/)test_[^/]*\.py$|Tests?\.(java|kt|cs)$|_spec\.rb$' \
  > "$TESTS.files" || true

# One line per test: <layer> TAB <path> TAB <name> TAB <normalized name + file stem>
while IFS= read -r f; do
  [ -f "$f" ] || continue
  lp="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  case "$lp" in
    *e2e*|*playwright*|*cypress*) layer="e2e" ;;
    *integration*|*.int.*|*api-test*|*api_test*) layer="integration" ;;
    *) layer="unit" ;;
  esac
  stem="$(basename "$f" | sed -E 's/\.[^.]+$//; s/\.(test|spec)$//; s/_(test|spec)$//; s/^test_//; s/Tests?$//')"
  grep -hoE "(^|[^A-Za-z0-9_.])(it|test|describe|context)(\.(only|skip|each\([^)]*\)))?\([[:space:]]*['\"\`][^'\"\`]+|def[[:space:]]+test_[A-Za-z0-9_]+|func[[:space:]]+Test[A-Za-z0-9_]+|@DisplayName\(\"[^\"]+|(void|fun|Task)[[:space:]]+[a-zA-Z][A-Za-z0-9_]*[[:space:]]*\(" "$f" 2>/dev/null \
    | sed -E "s/^[^A-Za-z0-9_]//; s/^(it|test|describe|context)(\.(only|skip|each\([^)]*\)))?\([[:space:]]*['\"\`]//; s/^def[[:space:]]+//; s/^func[[:space:]]+//; s/^@DisplayName\(\"//; s/^(void|fun|Task)[[:space:]]+//; s/[[:space:]]*\($//" \
    | while IFS= read -r name; do
        [ -n "$name" ] || continue
        norm="$(printf '%s %s\n' "$name" "$stem" | normalize)"
        printf '%s\t%s\t%s\t%s\n' "$layer" "$f" "$name" "$norm"
      done
done < "$TESTS.files" > "$TESTS"

# Items, normalized the same way (the keywords column only).
awk -F'\t' 'NF >= 3 && $1 !~ /^[[:space:]]*#/ { print $1 "\t" $2 "\t" $3 }' "$ITEMS" > "$TESTS.items"
cut -f3 "$TESTS.items" | normalize > "$TESTS.itemnorm"
paste "$TESTS.items" "$TESTS.itemnorm" > "$TESTS.itemsfull"

render() {
  awk -F'\t' -v layers="$LAYERS" -v testsfile="$TESTS" '
    BEGIN {
      split("a an and or the of to in on for with by is are be it its as at from that this when then given should must can will not no into via using use returns return test tests spec", sw, " ")
      for (i in sw) stop[sw[i]] = 1
      n = split(layers, ls, ",")
      for (i = 1; i <= n; i++) enabled[ls[i]] = 1
      nt = 0
      while ((getline line < testsfile) > 0) {
        split(line, c, "\t")
        nt++; tl[nt] = c[1]; tp[nt] = c[2]; tn[nt] = c[3]; tw[nt] = c[4]
      }
      close(testsfile)
    }
    function toks(s, arr,    w, k, i, m) {
      for (k in arr) delete arr[k]
      m = split(s, w, " ")
      cnt = 0
      for (i = 1; i <= m; i++) {
        if (w[i] == "" || length(w[i]) < 3 || (w[i] in stop)) continue
        w[i] = stem(w[i])
        if (!(w[i] in arr)) { arr[w[i]] = 1; cnt++ }
      }
      return cnt
    }
    function stem(w) {
      if (length(w) > 5 && w ~ /ing$/) return substr(w, 1, length(w) - 3)
      if (length(w) > 4 && w ~ /(ed|es)$/) return substr(w, 1, length(w) - 2)
      if (length(w) > 3 && w ~ /s$/ && w !~ /ss$/) return substr(w, 1, length(w) - 1)
      return w
    }
    function jaccard(a, na, b, nb,    k, inter) {
      if (na == 0 || nb == 0) return 0
      inter = 0
      for (k in a) if (k in b) inter++
      return inter / (na + nb - inter)
    }
    function band(j) { return j >= 0.5 ? "covered" : (j >= 0.3 ? "uncertain" : "uncovered") }
    function severity(j) { return j == 0 ? "high" : (j >= 0.3 && j < 0.5 ? "medium" : "-") }
    function best_in(layer, words,    ia, na, t, tb, nb, j) {
      na = toks(words, ia)
      bj = 0; bt = 0
      for (t = 1; t <= nt; t++) {
        if (tl[t] != layer) continue
        nb = toks(tw[t], tb)
        j = jaccard(ia, na, tb, nb)
        if (j > bj) { bj = j; bt = t }
      }
    }
    function emit(id, layer, j, t,    st, sv) {
      st = band(j); sv = severity(j)
      counts[st]++
      if (sv != "-") findings[sv]++
      printf "| %s | %s | %.2f | %s | %s | %s |\n", id, layer, j, st, (t ? tp[t] " › " tn[t] : "none"), sv
    }
    {
      id = $1; layer = $2; words = $4
      if (layer == "-" || layer == "") {
        gj = -1; gt = 0; gl = ls[1]
        for (i = 1; i <= n; i++) {
          best_in(ls[i], words)
          if (bj > gj) { gj = bj; gt = bt; gl = ls[i] }
        }
        emit(id, gl, gj, gt)
      } else if (layer in enabled) {
        best_in(layer, words)
        emit(id, layer, bj, bt)
      } else {
        counts["disabled"]++
        printf "| %s | %s | - | disabled | - | - |\n", id, layer
      }
    }
    BEGIN {
      print "# Coverage correlation"
      print ""
      print "> Keyword Jaccard between each spec item and the tests of its layer. The uncertain band needs a human-grade look at the closest test before it is reported; covered and uncovered are reported as scored."
      print ""
      print "| Item | Layer | Confidence | Status | Closest test | Finding |"
      print "|------|-------|------------|--------|--------------|---------|"
    }
    END {
      printf "\ntests_scanned=%d\n", nt
      printf "covered=%d uncertain=%d uncovered=%d disabled=%d\n", counts["covered"], counts["uncertain"], counts["uncovered"], counts["disabled"]
      printf "findings: high=%d medium=%d\n", findings["high"], findings["medium"]
    }
  ' "$TESTS.itemsfull"
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  render > "$OUT"
  echo "$OUT"
else
  render
fi
