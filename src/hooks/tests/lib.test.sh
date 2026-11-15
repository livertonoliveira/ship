#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib.sh"
SHELL_BIN="${SHIP_TEST_BASH:-bash}"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

expect() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then log_pass "$name"; else log_fail "$name (want [$want] got [$got])"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
. "$LIB"

script() {
  local name="$1"
  { printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s"\n' "$LIB"; cat; } > "$TMP/$name"
}

run() {
  local name="$1"
  set +e
  RUN_OUT="$("$SHELL_BIN" "$TMP/$name" 2>"$TMP/stderr")"
  RUN_RC=$?
  set -e
  RUN_ERR="$(cat "$TMP/stderr")"
}

script grep-miss.sh <<'EOF'
echo before
value="$(printf 'a\n' | grep '^b')"
echo "after $value"
EOF
run grep-miss.sh
expect "a grep that matches nothing inside an assignment still ends the script" "1" "$RUN_RC"
expect "the death names the script and the line" "grep-miss.sh: stopped by a failing command at line 5 (exit 1)" "${RUN_ERR%%: value=*}"
expect "the death names the command" "1" "$(printf '%s' "$RUN_ERR" | grep -c '): value=')"
expect "stdout carries only what the script printed" "before" "$RUN_OUT"

script in-function.sh <<'EOF'
lookup() {
  local found
  found="$(false)"
  echo "$found"
}
lookup
EOF
run in-function.sh
expect "a death inside a function is reported once" "1" "$(printf '%s\n' "$RUN_ERR" | grep -c 'stopped by a failing command')"

script tolerated.sh <<'EOF'
value="$(printf 'a\n' | grep '^b' || true)"
if printf 'a\n' | grep -q '^b'; then echo hit; fi
missing="$(false; echo kept)"
printf 'a\n' | grep -q '^b' || echo miss
set +e
false
set -e
( exit 3 ) || echo "subshell $?"
echo "done $missing"
EOF
run tolerated.sh
expect "tolerated failures do not end the script" "0" "$RUN_RC"
expect "tolerated failures print nothing on stderr" "" "$RUN_ERR"
expect "tolerated failures leave stdout alone" "miss
subshell 3
done kept" "$RUN_OUT"

script deliberate.sh <<'EOF'
echo "gate=fail"
exit 1
EOF
run deliberate.sh
expect "a deliberate exit keeps its code" "1" "$RUN_RC"
expect "a deliberate exit is not a death" "" "$RUN_ERR"

script multiline.sh <<'EOF'
awk 'BEGIN {
  exit 3
}'
EOF
run multiline.sh
expect "only the first line of a multi-line command is quoted" "1" "$(printf '%s\n' "$RUN_ERR" | wc -l | tr -d ' ')"

script verdict.sh <<'EOF'
check() {
  echo "lost=a.test.ts"
  return 1
}
check
EOF
run verdict.sh
expect "a function's non-zero verdict keeps its code" "1" "$RUN_RC"
expect "a function's non-zero verdict is not a death" "" "$RUN_ERR"

script pipefail.sh <<'EOF'
printf 'a\n' | grep '^b' | head -1
echo unreachable
EOF
run pipefail.sh
expect "a failed pipeline is reported" "1" "$(printf '%s\n' "$RUN_ERR" | grep -c 'pipefail.sh: stopped by a failing command at line')"

DOC='{
  "id": "req_1",
  "ok": true,
  "result": {
    "run": { "id": "run_abc-9", "state": "open", "count": 3, "note": null },
    "path": "/tmp/a \"quoted\" dir/{x}",
    "items": [
      { "severity": "high", "title": "first" },
      { "severity": "low", "title": "say \"severity\": \"high\" twice" },
      { "severity": "high", "title": "line one\nline two\ttabbed \\n kept" }
    ],
    "scripts": { "glob": "eslint \"src/**/*.{ts,tsx}\"", "test:unit": "jest" }
  }
}'

expect "json_find returns the first value under a key" "req_1" "$(printf '%s' "$DOC" | json_find id)"
expect "json_find reads a boolean" "true" "$(printf '%s' "$DOC" | json_find ok)"
expect "json_find reads a number" "3" "$(printf '%s' "$DOC" | json_find count)"
expect "json_find decodes escaped quotes and keeps braces" '/tmp/a "quoted" dir/{x}' "$(printf '%s' "$DOC" | json_find path)"
expect "json_find skips a null" "" "$(printf '%s' "$DOC" | json_find note)"
expect "json_find prints nothing for a missing key" "" "$(printf '%s' "$DOC" | json_find nope)"
expect "a missing key is not a failure" "0" "$(printf '%s' "$DOC" | json_find nope >/dev/null; echo $?)"
expect "a dotted key is a path suffix" "run_abc-9" "$(printf '%s' "$DOC" | json_find run.id)"
expect "a dotted key matches whole segments only" "" "$(printf '%s' "$DOC" | json_find un.id)"
expect "json_get reads an exact path" "run_abc-9" "$(printf '%s' "$DOC" | json_get .result.run.id)"
expect "json_get reads through an array" "low" "$(printf '%s' "$DOC" | json_get '.result.items[1].severity')"
expect "json_get reads a key past a brace glob in an earlier value" "jest" "$(printf '%s' "$DOC" | json_get '.result.scripts.test:unit')"
expect "json_get keeps the glob itself" 'eslint "src/**/*.{ts,tsx}"' "$(printf '%s' "$DOC" | json_get .result.scripts.glob)"
expect "json_count ignores a key-shaped text inside a string" "2" "$(printf '%s' "$DOC" | json_count severity high)"
expect "json_count answers 0 for no match" "0" "$(printf '%s' "$DOC" | json_count severity critical)"
expect "json_find_all lists every value in order" "high
low
high" "$(printf '%s' "$DOC" | json_find_all severity)"
expect "json_first_like finds a value by shape, not the envelope id" "run_abc-9" "$(printf '%s' "$DOC" | json_first_like '^run_[0-9a-zA-Z_-]+$')"
expect "a string is decoded: newline, tab, escaped backslash" "line one
line two	tabbed \\n kept" "$(printf '%s' "$DOC" | json_get '.result.items[2].title')"
expect "json_stream prints path, type and an escaped value" '.result.items[2].title	s	line one\nline two\ttabbed \\n kept' "$(printf '%s' "$DOC" | json_stream | grep -F 'items[2].title')"
expect "json_stream_flat keeps a value on one line and a backslash as itself" '.result.items[2].title	s	line one line two tabbed \n kept' "$(printf '%s' "$DOC" | json_stream_flat | grep -F 'items[2].title')"
expect "json_stream announces containers, empty ones included" '.a	o	
.a.b	a	' "$(printf '{"a":{"b":[]}}' | json_stream | tail -2)"
expect "json_stream marks literals" '.result.run.note	l	null' "$(printf '%s' "$DOC" | json_stream | grep -F '.note')"

printf '%s' "$DOC" > "$TMP/doc.json"
expect "a file argument is read instead of stdin" "open" "$(json_find state "$TMP/doc.json")"
expect "single-line JSON reads the same" "/x/y.ts" "$(printf '{"cwd":"/w","tool_input":{"file_path":"/x/y.ts","content":"\\"file_path\\": \\"/evil\\""}}' | json_find file_path)"
expect "a key is not found inside an array of strings" "" "$(printf '{"a":["b","c"]}' | json_find b)"
expect "an array of scalars is addressable" "c" "$(printf '{"a":["b","c"]}' | json_get '.a[1]')"
expect "a low \\u escape is decoded" "a/b" "$(printf '{"k":"a\\u002fb"}' | json_find k)"
expect "a \\u escape becomes UTF-8" 'café' "$(printf '{"k":"caf\\u00e9"}' | json_find k)"
expect "a surrogate pair becomes one character" '😀!' "$(printf '{"k":"\\ud83d\\ude00!"}' | json_find k)"
expect "raw UTF-8 passes through" 'título — ok' "$(printf '{"k":"título — ok"}' | json_find k)"
expect "an empty document prints nothing" "" "$(printf '' | json_find k)"
expect "a trailing escaped backslash closes its string" 'C:\' "$(printf '{"k":"C:\\\\","z":"1"}' | json_find k)"

expect "nodes_json_rows reads a node by name, whatever the order" 'A		título "x"		src/a.ts,b/**	10
B			A	x,y	' "$(printf '[{"id":"A","title":"t\\u00edtulo \\"x\\"","deps":[],"files":["src/a.ts","b/**"],"lines":10,"repo":null},{"files":"x,y","id":"B","deps":["A"],"meta":{"id":"no"}}]' | nodes_json_rows)"

echo
echo "$pass_count passed, $fail_count failed"
if [ "$fail_count" -ne 0 ]; then exit 1; fi
