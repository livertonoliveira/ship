#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEUR="$SCRIPT_DIR/../audit-heuristics.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# make_repo <dir> <path> <content> [<path> <content> ...]
make_repo() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git config user.email t@t
    git config user.name t
    while [ $# -gt 0 ]; do
      mkdir -p "$(dirname "$1")"
      printf '%s\n' "$2" > "$1"
      shift 2
    done
    git add -A
    git commit -qm init
  ) >/dev/null
}

run_in() {
  local dir="$1"
  shift
  (cd "$dir" && bash "$HEUR" "$@")
}

# The rule ids (## headings) that produced at least one candidate.
rules_hit() {
  awk '/^## / { id = $2; print id }' <<<"$1"
}

assert_hit() {
  local name="$1" out="$2" rule="$3"
  if rules_hit "$out" | grep -qx "$rule"; then log_pass "$name"; else log_fail "$name (no '$rule' in output)"; fi
}

assert_no_hit() {
  local name="$1" out="$2" rule="$3"
  if rules_hit "$out" | grep -qx "$rule"; then log_fail "$name ('$rule' should not fire)"; else log_pass "$name"; fi
}

test_backend_rules_fire_on_their_triggers() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" \
    src/a.ts "$(printf '%s\n' \
      'const cache = new Map<string, number>();' \
      'ids.forEach(async (id) => {' \
      '  await User.findOne({ _id: id });' \
      '});' \
      "const raw = fs.readFileSync('x');" \
      "console.log('login', password);")"
  out="$(run_in "$d" backend)"
  assert_hit "n-plus-one fires on an awaited query inside forEach(async)" "$out" n-plus-one
  assert_hit "blocking-io fires on a sync call in an async file" "$out" blocking-io
  assert_hit "memory-growth fires on a module-level Map never evicted" "$out" memory-growth
  assert_hit "secret-in-log fires on a logged password" "$out" secret-in-log
}

test_companion_pattern_suppresses_absent_rules() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" \
    src/a.ts "$(printf '%s\n' \
      'const cache = new Map();' \
      'export function drop(k) { cache.delete(k); }' \
      'await fetch(url, { signal: AbortSignal.timeout(5000) });')"
  out="$(run_in "$d" backend)"
  assert_no_hit "memory-growth stays quiet when the file evicts" "$out" memory-growth
  assert_no_hit "request-timeout stays quiet with an AbortSignal nearby" "$out" request-timeout
}

test_sql_rules_are_case_insensitive() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" \
    db/schema.sql "$(printf '%s\n' \
      'create table users (' \
      '  org_id int,' \
      '  bio varchar(2000)' \
      ') engine=MyISAM default charset=utf8;')"
  out="$(run_in "$d" mysql)"
  assert_hit "myisam-engine matches lower-case DDL" "$out" myisam-engine
  assert_hit "utf8-charset matches utf8 but not utf8mb4" "$out" utf8-charset
  assert_hit "fk-missing fires on an _id column without REFERENCES" "$out" fk-missing
  assert_hit "varchar-excessive fires above 1000" "$out" varchar-excessive
}

test_utf8mb4_is_not_flagged() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" db/schema.sql 'CREATE TABLE t (id INT) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;'
  out="$(run_in "$d" mysql)"
  assert_no_hit "utf8mb4 is not flagged" "$out" utf8-charset
}

test_test_files_are_excluded() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" \
    test/login.test.ts "console.log('x', password);" \
    src/login.spec.ts "console.log('x', password);"
  out="$(run_in "$d" backend)"
  assert_no_hit "test and spec files are not scanned" "$out" secret-in-log
}

test_sqlite_uses_the_postgresql_rules() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" db/q.sql 'SELECT * FROM users;'
  out="$(run_in "$d" SQLite)"
  assert_hit "sqlite routes to the postgresql rule set" "$out" select-star-no-limit
}

test_header_states_candidates_not_findings() {
  local d out; d="$(mktemp -d)"
  make_repo "$d" README.md 'hi'
  out="$(run_in "$d" backend)"
  if grep -q '^> Candidates, not findings' <<<"$out" && grep -q '^No candidates\.$' <<<"$out"; then
    log_pass "header says candidates, empty run says so"
  else
    log_fail "header/empty-state wording missing"
  fi
}

test_cap_is_announced() {
  local d out lines; d="$(mktemp -d)"
  lines="$(for i in 1 2 3 4; do echo "console.log('t', token$i);"; done)"
  make_repo "$d" src/a.ts "$lines"
  out="$(run_in "$d" backend --max-per-rule 2)"
  if grep -q '^- … 2 more$' <<<"$out"; then log_pass "hits beyond the cap are counted"; else log_fail "cap not announced"; fi
}

test_unknown_set_fails() {
  local d; d="$(mktemp -d)"
  make_repo "$d" README.md 'hi'
  if run_in "$d" oracle >/dev/null 2>&1; then log_fail "unknown rule set accepted"; else log_pass "unknown rule set fails fast"; fi
}

test_backend_rules_fire_on_their_triggers
test_companion_pattern_suppresses_absent_rules
test_sql_rules_are_case_insensitive
test_utf8mb4_is_not_flagged
test_test_files_are_excluded
test_sqlite_uses_the_postgresql_rules
test_header_states_candidates_not_findings
test_cap_is_announced
test_unknown_set_fails

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
