#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

usage() {
  echo "usage: analyze-correlate.sh <spec-file> <diff-file> [--scratch <dir>] [--test-scope unit=enabled,integration=enabled,e2e=enabled] [--repo-root <dir>]" >&2
}

SPEC=""
DIFF=""
SCRATCH=""
TEST_SCOPE="unit=enabled,integration=enabled,e2e=enabled"
REPO_ROOT="."
MAX_TEST_FILES=400

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch) SCRATCH="$2"; shift 2 ;;
    --test-scope) TEST_SCOPE="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 1 ;;
    *)
      if [ -z "$SPEC" ]; then SPEC="$1"
      elif [ -z "$DIFF" ]; then DIFF="$1"
      else usage; exit 1
      fi
      shift ;;
  esac
done

if [ -z "$SPEC" ] || [ -z "$DIFF" ]; then
  usage
  exit 1
fi
if [ ! -f "$SPEC" ]; then
  echo "analyze-correlate.sh: spec file not found: $SPEC" >&2
  exit 1
fi
if [ ! -f "$DIFF" ]; then
  echo "analyze-correlate.sh: diff file not found: $DIFF" >&2
  exit 1
fi

scope_of() {
  local layer="$1" entry
  IFS=',' read -ra entries <<< "$TEST_SCOPE"
  for entry in "${entries[@]}"; do
    case "$entry" in
      "$layer="*) printf '%s' "${entry#*=}"; return 0 ;;
    esac
  done
  printf 'enabled'
}

UNIT_SCOPE="$(scope_of unit)"
INTEGRATION_SCOPE="$(scope_of integration)"
E2E_SCOPE="$(scope_of e2e)"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

DIFF_HASH="$(sha256 "$DIFF")"
SPEC_HASH="$(sha256 "$SPEC")"

if [ -n "$SCRATCH" ] && [ -f "$SCRATCH/jaccard.json" ]; then
  cached_diff="$(grep -o '"diff_hash":"[a-f0-9]*"' "$SCRATCH/jaccard.json" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
  cached_spec="$(grep -o '"spec_hash":"[a-f0-9]*"' "$SCRATCH/jaccard.json" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
  if [ "$cached_diff" = "$DIFF_HASH" ] && [ "$cached_spec" = "$SPEC_HASH" ]; then
    cat "$SCRATCH/jaccard.json"
    exit 0
  fi
fi

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

STOPWORDS="$TMPDIR_LOCAL/stopwords"
cat > "$STOPWORDS" <<'EOF'
the
and
for
with
that
this
from
must
should
shall
when
then
given
will
can
are
was
were
been
have
has
not
its
into
each
per
via
uma
umas
um
uns
de
do
da
dos
das
em
no
na
nos
nas
para
por
com
que
como
ser
ter
deve
devem
quando
entao
então
seja
sem
mais
menos
sobre
pelo
pela
aos
feature
background
scenario
outline
examples
and
but
export
import
function
func
def
return
const
let
var
val
class
interface
struct
type
extends
implements
new
throw
try
catch
finally
async
await
static
public
private
protected
void
null
undefined
nil
none
true
false
self
package
namespace
EOF

RECORDS="$TMPDIR_LOCAL/records.tsv"
: > "$RECORDS"

tokenize() {
  printf '%s\n' "$1" \
    | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g; s/([A-Z]+)([A-Z][a-z])/\1 \2/g' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '\n' \
    | awk 'length($0) >= 2' \
    | grep -v -x -F -f "$STOPWORDS" \
    | sort -u \
    | tr '\n' ' ' \
    | sed 's/ $//' || true
}

# --- Spec extraction: raw items to TYPE \t id \t meta \t layer \t text ---
awk '
  function clean(s) { gsub(/\t/, " ", s); gsub(/^[[:space:]#*>-]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
  function flush_sc() {
    if (sc_id != "") {
      print "SC\t" sc_id "\t" sc_ac "\t" sc_layer "\t" clean(sc_text)
      sc_id = ""
    }
  }
  /@SC-[0-9]+/ {
    flush_sc()
    sc_id = ""; sc_ac = ""; sc_layer = ""; sc_text = ""; kw = ""; ex_pending = 0
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^@SC-[0-9]+$/) sc_id = substr($i, 2)
      else if ($i ~ /^@AC-[0-9]+$/) sc_ac = substr($i, 2)
      else if ($i == "@unit" || $i == "@integration" || $i == "@e2e") sc_layer = substr($i, 2)
    }
    if (sc_id != "") in_sc = 1
    next
  }
  in_sc && /^[[:space:]]*Scenario( Outline)?:/ {
    line = $0
    sub(/^[[:space:]]*Scenario( Outline)?:[[:space:]]*/, "", line)
    sc_text = sc_text " " line
    next
  }
  in_sc && /^[[:space:]]*(Given|When|Then|And|But)[[:space:]]/ {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    first = line
    sub(/[[:space:]].*/, "", first)
    rest = line
    sub(/^[A-Za-z]+[[:space:]]+/, "", rest)
    if (first == "Given" || first == "When" || first == "Then") kw = first
    if (kw == "When" || kw == "Then") sc_text = sc_text " " rest
    next
  }
  in_sc && /^[[:space:]]*Examples:/ { ex_pending = 1; next }
  in_sc && ex_pending && /^[[:space:]]*\|/ {
    line = $0
    gsub(/\|/, " ", line)
    sc_text = sc_text " " line
    ex_pending = 0
    next
  }
  /^#/ || /^[[:space:]]*(Feature|Rule):/ { flush_sc(); in_sc = 0 }
  {
    line = $0
    if (match(line, /REQ-[0-9]+/)) {
      id = substr(line, RSTART, RLENGTH)
      after = substr(line, RSTART + RLENGTH)
      if (after ~ /^[[:space:]]*:/ || line ~ /^#/) {
        if (!(id in seen_req)) {
          seen_req[id] = 1
          desc = after
          sub(/^[[:space:]]*[:.—–-]+[[:space:]]*/, "", desc)
          if (desc == "") desc = line
          print "REQ\t" id "\t-\t-\t" clean(desc)
        }
        cur_req = id
      }
    }
    if (match(line, /AC-[0-9]+/) && line !~ /@AC-[0-9]+/) {
      id = substr(line, RSTART, RLENGTH)
      after = substr(line, RSTART + RLENGTH)
      if (after ~ /^[[:space:]]*:/) {
        if (!(id in seen_ac)) {
          seen_ac[id] = 1
          desc = after
          sub(/^[[:space:]]*[:.—–-]+[[:space:]]*/, "", desc)
          if (desc == "") desc = line
          req = (cur_req == "") ? "-" : cur_req
          print "AC\t" id "\t" req "\t-\t" clean(desc)
        }
      }
    }
  }
  END { flush_sc() }
' "$SPEC" > "$TMPDIR_LOCAL/spec-items.tsv"

# --- Diff extraction: path \t aggregated added text ---
awk '
  /^\+\+\+ b\// { cur = substr($0, 7); files[cur] = 1; next }
  /^\+\+\+ \/dev\/null/ { if (old != "") { files[old] = 1 }; cur = ""; next }
  /^--- a\// { old = substr($0, 7); next }
  /^--- \/dev\/null/ { old = ""; next }
  /^\+/ && cur != "" {
    line = substr($0, 2)
    gsub(/\t/, " ", line)
    txt[cur] = txt[cur] " " line
  }
  END {
    for (f in files) {
      p = f
      gsub(/\t/, " ", p)
      print p "\t" p " " txt[f]
    }
  }
' "$DIFF" | sort > "$TMPDIR_LOCAL/diff-files.tsv"

# --- Test discovery, layer classification, name extraction ---
layer_of() {
  local f="$1"
  case "$f" in
    *.e2e.*|*.e2e-spec.*|*/e2e/*|e2e/*|*/cypress/*|cypress/*|*/playwright/*|playwright/*) printf 'e2e' ;;
    *.integration.test.*|*.integration.spec.*|*__tests__/integration/*) printf 'integration' ;;
    *) printf 'unit' ;;
  esac
}

WORKSPACES="$TMPDIR_LOCAL/workspaces"
cut -f1 "$TMPDIR_LOCAL/diff-files.tsv" \
  | grep -E '^(apps|packages|services|libs|modules)/[^/]+/' \
  | sed -E 's#^([^/]+/[^/]+)/.*#\1#' \
  | sort -u > "$WORKSPACES" || true

SEARCH_ROOTS=()
if [ -s "$WORKSPACES" ]; then
  while IFS= read -r ws; do
    [ -d "$REPO_ROOT/$ws" ] && SEARCH_ROOTS+=("$REPO_ROOT/$ws")
  done < "$WORKSPACES"
fi
if [ "${#SEARCH_ROOTS[@]:-0}" -eq 0 ]; then
  SEARCH_ROOTS=("$REPO_ROOT")
fi

TEST_LIST="$TMPDIR_LOCAL/test-files"
find "${SEARCH_ROOTS[@]}" \
  \( -name node_modules -o -name dist -o -name build -o -name .git -o -name vendor -o -name coverage -o -name .next -o -name .context \) -prune \
  -o -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name '*_test.py' -o -name '*_test.go' -o -path '*__tests__*' -o -name '*.e2e.*' -o -name '*.e2e-spec.*' \) -print 2>/dev/null \
  | sed "s#^$REPO_ROOT/##; s#^\./##" | sort -u > "$TEST_LIST.all" || true

TRUNCATED_TESTS=false
if [ "$(grep -c '' "$TEST_LIST.all" 2>/dev/null || echo 0)" -gt "$MAX_TEST_FILES" ]; then
  TRUNCATED_TESTS=true
fi
head -n "$MAX_TEST_FILES" "$TEST_LIST.all" > "$TEST_LIST"

test_names_of() {
  local f="$1"
  {
    grep -hoE "(it|test|describe)\(['\"\`][^'\"\`]*" "$f" 2>/dev/null | sed -E "s/^(it|test|describe)\(['\"\`]//" || true
    grep -hoE '^[[:space:]]*def test_[a-zA-Z0-9_]+' "$f" 2>/dev/null | sed 's/.*def //' || true
    grep -hoE 'func Test[A-Za-z0-9_]+' "$f" 2>/dev/null | sed 's/func //' || true
  } | tr '\n' ' '
}

# --- Assemble records with token sets ---
while IFS=$'\t' read -r type id meta layer text; do
  toks="$(tokenize "$text")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$id" "$meta" "$layer" "$text" "$toks" >> "$RECORDS"
done < "$TMPDIR_LOCAL/spec-items.tsv"

while IFS=$'\t' read -r path text; do
  case "$path" in
    ship/changes/*|ship/audits/*|.context/*) continue ;;
  esac
  toks="$(tokenize "$text")"
  printf 'FILE\t%s\t-\t-\t-\t%s\n' "$path" "$toks" >> "$RECORDS"
done < "$TMPDIR_LOCAL/diff-files.tsv"

while IFS= read -r tf; do
  [ -n "$tf" ] || continue
  layer="$(layer_of "$tf")"
  case "$layer" in
    unit) [ "$UNIT_SCOPE" = "enabled" ] || continue ;;
    integration) [ "$INTEGRATION_SCOPE" = "enabled" ] || continue ;;
    e2e) [ "$E2E_SCOPE" = "enabled" ] || continue ;;
  esac
  src_path="$REPO_ROOT/$tf"
  [ -f "$src_path" ] || src_path="$tf"
  [ -f "$src_path" ] || continue
  names="$(test_names_of "$src_path")"
  toks="$(tokenize "$tf $names")"
  printf 'TESTF\t%s\t-\t%s\t-\t%s\n' "$tf" "$layer" "$toks" >> "$RECORDS"
done < "$TEST_LIST"

# --- Correlation + JSON emission ---
OUTPUT="$(awk -F'\t' \
  -v diff_hash="$DIFF_HASH" -v spec_hash="$SPEC_HASH" \
  -v unit_scope="$UNIT_SCOPE" -v integration_scope="$INTEGRATION_SCOPE" -v e2e_scope="$E2E_SCOPE" \
  -v truncated="$TRUNCATED_TESTS" '
  function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\r/, "", s); return s }
  function jaccard(a, b,   ta, tb, seen, i, na, nb, inter, uni) {
    if (a == "" || b == "") return 0
    delete seen
    na = split(a, ta, " "); nb = split(b, tb, " ")
    uni = 0; inter = 0
    for (i = 1; i <= na; i++) { if (!(("A" ta[i]) in seen)) { seen["A" ta[i]] = 1; uni++ } }
    for (i = 1; i <= nb; i++) {
      if (("B" tb[i]) in seen) continue
      seen["B" tb[i]] = 1
      if (("A" tb[i]) in seen) inter++
      else uni++
    }
    return (uni == 0) ? 0 : inter / uni
  }
  function ignored(f) {
    if (f ~ /\.lock$/ || f ~ /package-lock\.json$/ || f ~ /pnpm-lock\.yaml$/) return 1
    if (f ~ /\.config\./ || f ~ /tsconfig[^\/]*\.json$/ || f ~ /\.eslintrc/) return 1
    if (f ~ /\.generated\./ || f ~ /^dist\// || f ~ /\/dist\// || f ~ /^build\// || f ~ /\/build\//) return 1
    return 0
  }
  function scope_enabled(l) {
    if (l == "unit") return unit_scope == "enabled"
    if (l == "integration") return integration_scope == "enabled"
    if (l == "e2e") return e2e_scope == "enabled"
    return 0
  }
  $1 == "REQ" { nreq++; req_id[nreq] = $2; req_desc[nreq] = $5; req_tok[nreq] = $6 }
  $1 == "AC" { nac++; ac_id[nac] = $2; ac_req[nac] = $3; ac_desc[nac] = $5; ac_tok[nac] = $6 }
  $1 == "SC" { nsc++; sc_id[nsc] = $2; sc_ac[nsc] = $3; sc_layer[nsc] = ($4 == "" ? "-" : $4); sc_desc[nsc] = $5; sc_tok[nsc] = $6 }
  $1 == "FILE" { nfile++; file_path[nfile] = $2; file_tok[nfile] = $6 }
  $1 == "TESTF" { ntest++; test_path[ntest] = $2; test_layer[ntest] = $4; test_tok[ntest] = $6 }
  END {
    printf "{\"diff_hash\":\"%s\",\"spec_hash\":\"%s\",", diff_hash, spec_hash
    printf "\"test_scope\":{\"unit\":\"%s\",\"integration\":\"%s\",\"e2e\":\"%s\"},", unit_scope, integration_scope, e2e_scope
    printf "\"truncated_tests\":%s,", truncated

    printf "\"requirements\":["
    for (r = 1; r <= nreq; r++) {
      best = 0; bestf = ""
      for (f = 1; f <= nfile; f++) {
        s = jaccard(req_tok[r], file_tok[f])
        if (s > best) { best = s; bestf = file_path[f] }
      }
      req_best[r] = best
      printf "%s{\"id\":\"%s\",\"description\":\"%s\",\"confidence\":%.4f,\"file\":%s}", \
        (r > 1 ? "," : ""), req_id[r], jesc(req_desc[r]), best, (bestf == "" ? "null" : "\"" jesc(bestf) "\"")
      if (best >= 0.5) req_impl++; else if (best > 0) req_unc++; else req_unimpl++
    }
    printf "],"

    printf "\"criteria\":["
    for (a = 1; a <= nac; a++) {
      best = 0; bestf = ""; bestl = ""
      for (t = 1; t <= ntest; t++) {
        s = jaccard(ac_tok[a], test_tok[t])
        if (s > best) { best = s; bestf = test_path[t]; bestl = test_layer[t] }
      }
      printf "%s{\"id\":\"%s\",\"req\":%s,\"description\":\"%s\",\"confidence\":%.4f,\"file\":%s,\"layer\":%s}", \
        (a > 1 ? "," : ""), ac_id[a], (ac_req[a] == "-" ? "null" : "\"" ac_req[a] "\""), jesc(ac_desc[a]), best, \
        (bestf == "" ? "null" : "\"" jesc(bestf) "\""), (bestl == "" ? "null" : "\"" bestl "\"")
      if (best >= 0.5) ac_cov++; else if (best > 0) ac_unc++; else ac_uncov++
    }
    printf "],"

    printf "\"scenarios\":["
    first = 1
    for (c = 1; c <= nsc; c++) {
      l = sc_layer[c]
      if (l != "-" && !scope_enabled(l)) { disabled[l] = disabled[l] (disabled[l] == "" ? "" : ",") "\"" sc_id[c] "\""; sc_skipped++; continue }
      best = 0; bestf = ""
      for (t = 1; t <= ntest; t++) {
        if (l != "-" && test_layer[t] != l) continue
        s = jaccard(sc_tok[c], test_tok[t])
        if (s > best) { best = s; bestf = test_path[t] }
      }
      printf "%s{\"id\":\"%s\",\"ac\":%s,\"layer\":%s,\"description\":\"%s\",\"confidence\":%.4f,\"file\":%s}", \
        (first ? "" : ","), sc_id[c], (sc_ac[c] == "" || sc_ac[c] == "-" ? "null" : "\"" sc_ac[c] "\""), \
        (l == "-" ? "null" : "\"" l "\""), jesc(sc_desc[c]), best, (bestf == "" ? "null" : "\"" jesc(bestf) "\"")
      first = 0
      if (best >= 0.5) sc_cov++; else if (best > 0) sc_unc++; else sc_uncov++
    }
    printf "],"

    if (unit_scope != "enabled") for (a = 1; a <= nac; a++) disabled["unit"] = disabled["unit"] (disabled["unit"] == "" ? "" : ",") "\"" ac_id[a] "\""
    if (integration_scope != "enabled") for (a = 1; a <= nac; a++) disabled["integration"] = disabled["integration"] (disabled["integration"] == "" ? "" : ",") "\"" ac_id[a] "\""
    if (e2e_scope != "enabled") for (a = 1; a <= nac; a++) disabled["e2e"] = disabled["e2e"] (disabled["e2e"] == "" ? "" : ",") "\"" ac_id[a] "\""
    printf "\"disabled_layers\":{"
    first = 1
    for (l in disabled) {
      printf "%s\"%s\":[%s]", (first ? "" : ","), l, disabled[l]
      first = 0
    }
    printf "},"

    printf "\"orphans\":["
    first = 1
    if (nfile > 0 && nreq > 0) {
      for (f = 1; f <= nfile; f++) {
        if (ignored(file_path[f])) continue
        best = 0
        for (r = 1; r <= nreq; r++) {
          s = jaccard(file_tok[f], req_tok[r])
          if (s > best) best = s
        }
        if (best == 0) {
          printf "%s{\"file\":\"%s\",\"confidence\":0}", (first ? "" : ","), jesc(file_path[f])
          first = 0
          norph++
        }
      }
    }
    printf "],"

    printf "\"duplicates\":["
    first = 1
    for (r = 1; r <= nreq; r++) for (r2 = r + 1; r2 <= nreq; r2++) {
      s = jaccard(req_tok[r], req_tok[r2])
      if (s >= 0.8) { printf "%s{\"a\":\"%s\",\"b\":\"%s\",\"score\":%.4f}", (first ? "" : ","), req_id[r], req_id[r2], s; first = 0; ndup++ }
    }
    for (a = 1; a <= nac; a++) for (a2 = a + 1; a2 <= nac; a2++) {
      s = jaccard(ac_tok[a], ac_tok[a2])
      if (s >= 0.8) { printf "%s{\"a\":\"%s\",\"b\":\"%s\",\"score\":%.4f}", (first ? "" : ","), ac_id[a], ac_id[a2], s; first = 0; ndup++ }
    }
    printf "],"

    printf "\"summary\":{"
    printf "\"requirements\":{\"total\":%d,\"implemented\":%d,\"uncertain\":%d,\"unimplemented\":%d},", nreq, req_impl, req_unc, req_unimpl
    printf "\"criteria\":{\"total\":%d,\"covered\":%d,\"uncertain\":%d,\"uncovered\":%d},", nac, ac_cov, ac_unc, ac_uncov
    printf "\"scenarios\":{\"total\":%d,\"covered\":%d,\"uncertain\":%d,\"uncovered\":%d,\"skipped_disabled\":%d},", nsc, sc_cov, sc_unc, sc_uncov, sc_skipped
    printf "\"changed_files\":%d,\"test_files\":%d,\"orphans\":%d,\"duplicates\":%d", nfile, ntest, norph, ndup
    printf "}}"
  }
' "$RECORDS")"

if [ -n "$SCRATCH" ]; then
  mkdir -p "$SCRATCH"
  printf '%s\n' "$OUTPUT" > "$SCRATCH/jaccard.json"
fi
printf '%s\n' "$OUTPUT"
