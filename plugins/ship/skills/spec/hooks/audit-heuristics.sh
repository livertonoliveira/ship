#!/usr/bin/env bash

# audit-heuristics.sh <mongodb|postgresql|mysql|sqlite|backend> [--out <file>] [--max-per-rule N]
#
# The pattern-matching half of the database and backend audits: every rule is
# "a trigger line, with (or without) a companion pattern within N lines", which
# is a grep, not a judgment. Running it here gives the audit agent a candidate
# list in one pass; the agent spends its context confirming each hit against
# its surroundings and looking for what no pattern can express.
#
# Output is CANDIDATES, never findings — the header says so, because a
# candidate list treated as the finding list reports every false positive and
# misses every risk the rules cannot see.

set -euo pipefail

SET=""
OUT=""
MAX=50

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --max-per-rule) MAX="$2"; shift 2 ;;
    -h|--help)
      echo "usage: audit-heuristics.sh <mongodb|postgresql|mysql|sqlite|backend> [--out <file>] [--max-per-rule N]" >&2
      exit 0 ;;
    -*) echo "audit-heuristics.sh: unknown argument: $1" >&2; exit 1 ;;
    *)
      if [ -z "$SET" ]; then SET="$1"; shift
      else echo "audit-heuristics.sh: unexpected argument: $1" >&2; exit 1
      fi ;;
  esac
done

SET="$(printf '%s' "$SET" | tr '[:upper:]' '[:lower:]')"
case "$SET" in
  mongodb|postgresql|mysql|backend) ;;
  sqlite) SET="postgresql" ;;
  '') echo "audit-heuristics.sh: missing rule set (mongodb|postgresql|mysql|sqlite|backend)" >&2; exit 1 ;;
  *) echo "audit-heuristics.sh: unknown rule set: $SET" >&2; exit 1 ;;
esac

case "$MAX" in
  *[!0-9]*|'') echo "audit-heuristics.sh: --max-per-rule must be an integer: $MAX" >&2; exit 1 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "audit-heuristics.sh: not inside a git work tree" >&2
  exit 1
fi

FILES="$(mktemp)"
RULES="$(mktemp)"
trap 'rm -f "$FILES" "$RULES"' EXIT

git ls-files 2>/dev/null \
  | grep -vE '(^|/)(node_modules|vendor|dist|build|out|target|\.next|__pycache__|coverage)(/|$)' \
  | grep -vE '(^|/)(test|tests|__tests__|spec|e2e)/|\.(test|spec)\.[a-z]+$' \
  | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|py|go|java|kt|rb|php|cs|sql|ya?ml|conf|cnf|ini|properties)$' \
  > "$FILES" || true

# Columns (tab-separated): set, id, severity, class, kind, window, case, trigger, other, hint
#   class  code = source files · sql = .sql + source · config = everything listed above
#   kind   line = trigger alone · absent = no `other` within ±window lines
#          present = `other` within ±window lines · file-absent = no `other` anywhere in the file
#   case   i = match against the lower-cased line (write the patterns lower-case)
# Patterns are POSIX ERE as BSD awk reads them: [[:space:]], no \s, no \b, no {n,m}.
cat > "$RULES" <<'EOF'
mongodb	write-concern	critical	code	line	0	-	(^|[^A-Za-z0-9_])w[[:space:]]*:[[:space:]]*0([^0-9.]|$)	-	use w:1 or "majority"
mongodb	bson-limit	high	code	absent	5	-	Schema\.Types\.Mixed|\[[[:space:]]*(new[[:space:]]+)?[A-Z][A-Za-z]*Schema	maxlength|maxLength|validate	move to a separate collection or bound the array
mongodb	unbounded-array	medium	code	absent	5	-	\[[[:space:]]*(String|Number|ObjectId|Schema\.Types\.ObjectId)[[:space:]]*\]	maxlength|maxLength|validate	bound the array (16MB BSON cap)
mongodb	push-without-slice	medium	code	absent	15	-	\$push	\$slice	{$push:{field:{$each:[v],$slice:-N}}}
mongodb	upsert-no-unique-index	high	code	absent	10	-	upsert[[:space:]]*:[[:space:]]*true	unique[[:space:]]*:[[:space:]]*true	unique index on the filter fields + handle E11000
mongodb	collection-scan	high	code	line	0	-	\.find\([[:space:]]*\{[[:space:]]*\}	-	always filter
mongodb	aggregate-without-match	high	code	absent	3	-	\.aggregate\(	\$match	put $match first
mongodb	query-index	high	code	line	0	-	\.(find|findOne|findMany)\([[:space:]]*\{[[:space:]]*[A-Za-z_"'$]	-	confirm a supporting (compound) index exists for the filter
mongodb	lookup-index	high	code	line	0	-	\$lookup	-	index foreignField in the target collection
mongodb	fulltext-no-text-index	high	code	file-absent	0	-	\$text|\$search	['"]text['"]	create a text index
mongodb	in-variable	medium	code	line	0	-	\$in[[:space:]]*:[[:space:]]*[A-Za-z_]	-	cap or batch the list
mongodb	regex-unanchored	medium	code	line	0	-	\$regex[[:space:]]*:[[:space:]]*(['"][^'"^]|/[^^])	-	anchor with ^ or use $text
mongodb	slow-query	medium	code	absent	10	-	\.(find|findOne|aggregate)\(	maxTimeMS	chain .maxTimeMS()
mongodb	connection-pool	medium	code	absent	15	-	mongoose\.connect\(|new[[:space:]]+MongoClient\(|MongoClient\.connect\(	maxPoolSize	size maxPoolSize by CPU/concurrency
postgresql	select-star-no-limit	high	sql	absent	3	i	select[[:space:]]+\*	limit	explicit columns + LIMIT; verify with EXPLAIN (ANALYZE, BUFFERS)
postgresql	for-update-no-timeout	high	sql	absent	20	i	for[[:space:]]+update	lock_timeout|statement_timeout|nowait|skip[[:space:]]+locked	SET lock_timeout; NOWAIT / SKIP LOCKED
postgresql	autovacuum	high	config	line	0	i	autovacuum[[:space:]]*=[[:space:]]*'?off|autovacuum_vacuum_scale_factor[[:space:]]*=[[:space:]]*'?(0\.[6-9]|[1-9])	-	keep autovacuum on; scale factor ~0.01 on large tables
postgresql	json-vs-jsonb	medium	sql	line	0	i	[[:space:]]json([[:space:],)]|$)	-	use JSONB
postgresql	dml-outside-transaction	medium	sql	absent	7	i	(^|[^a-z_])(insert[[:space:]]+into|update[[:space:]]+[a-z_".]+[[:space:]]+set|delete[[:space:]]+from)	begin|commit|transaction	wrap related DML in a transaction
postgresql	trigger-without-when	medium	sql	absent	10	i	create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?trigger	when[[:space:]]*\(	scope the trigger with WHEN
postgresql	connection-pool	medium	code	absent	10	-	new[[:space:]]+Pool\(|createPool\(	max[[:space:]]*:	size max by max_connections / instance count
postgresql	fk-not-deferrable	low	sql	absent	2	i	foreign[[:space:]]+key	deferrable	DEFERRABLE INITIALLY DEFERRED where bulk loads need it
mysql	myisam-engine	high	sql	line	0	i	engine[[:space:]]*=[[:space:]]*myisam	-	migrate to InnoDB
mysql	utf8-charset	high	sql	line	0	i	(charset|character[[:space:]]+set)[[:space:]]*=?[[:space:]]*'?utf8([^m]|$)	-	migrate to utf8mb4
mysql	innodb-buffer-pool	medium	config	line	0	i	innodb_buffer_pool_size	-	70-80% of RAM on a dedicated host; flag if under 128MB
mysql	query-cache	medium	config	line	0	i	query_cache_type[[:space:]]*=[[:space:]]*'?(1|on|demand)|query_cache_size[[:space:]]*=[[:space:]]*'?[1-9]	-	disable (removed in MySQL 8.0)
mysql	fk-missing	medium	sql	absent	30	i	^[[:space:]]*`?[a-z_]+_id`?[[:space:]]+(int|bigint|integer)	foreign[[:space:]]+key|references	FOREIGN KEY (column) REFERENCES table(id)
mysql	varchar-excessive	low	sql	line	0	i	varchar\((100[1-9]|10[1-9][0-9]|1[1-9][0-9][0-9]|[2-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9])	-	use a realistic max length
backend	n-plus-one	medium	code	present	5	-	\.(forEach|map)\([[:space:]]*async	await[^;]*\.(find|findOne|findMany|findById|query|save|get)\(	prefetch/batch (Promise.all, eager load)
backend	missing-cache	low	code	absent	10	i	\.get\([[:space:]]*['"]/|@get\(	cache	cache directive/middleware on read-heavy routes
backend	pessimistic-lock	medium	code	absent	20	i	for[[:space:]]+update	nowait|skip[[:space:]]+locked|lock_timeout|transaction|begin	lock timeout + explicit transaction
backend	blocking-io	medium	code	present	30	-	(readFileSync|writeFileSync|appendFileSync|readdirSync|statSync|execSync|spawnSync)\(	async	use the async equivalent
backend	memory-growth	medium	code	file-absent	0	-	^(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[^=]*=[[:space:]]*new[[:space:]]+(Map|Set)[(<]	\.delete\(|\.clear\(|LRU|lru	bound with an LRU or periodic eviction
backend	request-timeout	medium	code	absent	10	-	axios(\.(get|post|put|patch|delete|request))?\(|(^|[^A-Za-z_.])fetch\(	timeout|AbortController|AbortSignal	add a timeout
backend	secret-in-log	high	code	line	0	i	(console\.(log|info|warn|error|debug)|logger\.[a-z]+|log\.[a-z]+)\(.*(password|passwd|token|secret|apikey|api_key|credential)	-	redact or drop from the log
EOF

render() {
  awk -F'\t' -v set="$SET" -v max="$MAX" -v list="$FILES" '
    FNR == NR {
      if ($1 != set) next
      nr++
      id[nr] = $2; sev[nr] = $3; cls[nr] = $4; kind[nr] = $5; win[nr] = $6 + 0
      ci[nr] = ($7 == "i"); trig[nr] = $8; other[nr] = $9; hint[nr] = $10
      next
    }
    END {
      while ((getline path < list) > 0) {
        fclass = "config"
        if (path ~ /\.sql$/) fclass = "sql"
        else if (path ~ /\.(ts|tsx|js|jsx|mjs|cjs|py|go|java|kt|rb|php|cs)$/) fclass = "code"
        n = 0
        while ((getline line < path) > 0) { n++; L[n] = line; LL[n] = tolower(line) }
        close(path)
        for (r = 1; r <= nr; r++) {
          if (cls[r] == "code" && fclass != "code") continue
          if (cls[r] == "sql" && fclass == "config") continue
          infile = 0
          if (kind[r] == "file-absent") {
            for (k = 1; k <= n; k++) {
              s = ci[r] ? LL[k] : L[k]
              if (s ~ other[r]) { infile = 1; break }
            }
            if (infile) continue
          }
          for (k = 1; k <= n; k++) {
            s = ci[r] ? LL[k] : L[k]
            if (s !~ trig[r]) continue
            hit = 1
            if (kind[r] == "absent" || kind[r] == "present") {
              found = 0
              lo = k - win[r]; if (lo < 1) lo = 1
              hi = k + win[r]; if (hi > n) hi = n
              for (j = lo; j <= hi; j++) {
                t = ci[r] ? LL[j] : L[j]
                if (t ~ other[r]) { found = 1; break }
              }
              hit = (kind[r] == "absent") ? !found : found
            }
            if (!hit) continue
            count[r]++
            if (count[r] <= max) {
              snip = L[k]; sub(/^[[:space:]]+/, "", snip)
              if (length(snip) > 160) snip = substr(snip, 1, 157) "..."
              out[r] = out[r] "- " path ":" k ": `" snip "`\n"
            }
          }
        }
        for (k = 1; k <= n; k++) { delete L[k]; delete LL[k] }
      }
      printf "# Audit heuristics — %s\n\n", set
      printf "> Candidates, not findings. Confirm each hit against its surrounding code, schema and config before reporting it, and report risks these rules cannot express as well. Rules with no hits are omitted.\n"
      total = 0
      for (r = 1; r <= nr; r++) {
        if (!count[r]) continue
        total += count[r]
        printf "\n## %s (%s) — %s\n\n%s", id[r], sev[r], hint[r], out[r]
        if (count[r] > max) printf "- … %d more\n", count[r] - max
      }
      if (!total) printf "\nNo candidates.\n"
    }
  ' "$RULES"
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  render > "$OUT"
  echo "$OUT"
else
  render
fi
