#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH="$SCRIPT_DIR/../graph.sh"

pass_count=0
fail_count=0

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

# A project of 192 issues stopped a coordinator before it built anything: the
# skill had the model read every description (~8k tokens each) to extract two
# blocks a script can read. These pin the script that replaced that step.

# Stands in for curl: serves $FAKE_DIR/page-<n>.json in order, and records the
# argv and the stdin config of every call.
install_fake_curl() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
printf '%s\n' "$*" >> "$FAKE_DIR/argv"
cat >> "$FAKE_DIR/stdin"
for a in "$@"; do
  case "$a" in @*) cat "${a#@}" >> "$FAKE_DIR/bodies"; echo >> "$FAKE_DIR/bodies" ;; esac
done
cat "$FAKE_DIR/page-$n.json"
EOF
  chmod +x "$dir/bin/curl"
}

run_nodes() {
  local dir="$1"
  shift
  FAKE_DIR="$dir" PATH="$dir/bin:$PATH" LINEAR_API_KEY="lin_api_secret" bash "$GRAPH" nodes --from-linear "$@"
}

test_project_is_read_across_pages() {
  local name="nodes --from-linear follows the cursor and emits one node per open issue"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  cat > "$dir/page-1.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-1","title":"Schema","description":"## Contexto\ntexto\n\n## Files\n- create `src/db/schema.ts` — tabela\n\n## Deps\nnone","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":true,"endCursor":"CUR-1"}}}}
EOF
  cat > "$dir/page-2.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-2","title":"Endpoint","description":"## Files\n\n* modify `src/api/routes.ts` — rota\n  Âncora: siga o padrão de `src/api/other.ts` — x\n\n## Deps\n\n* MOB-1","state":{"type":"backlog"},"labels":{"nodes":[{"name":"backend"},{"name":"repo:api"}]},"inverseRelations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":false,"endCursor":"CUR-2"}}}}
EOF
  out="$(run_nodes "$dir" "Revisão Arquitetural")"

  if [ "$(cat "$dir/calls")" = "2" ] \
    && grep -q '"a":null' "$dir/bodies" \
    && grep -q '"a":"CUR-1"' "$dir/bodies" \
    && grep -q '"p":"Revisão Arquitetural"' "$dir/bodies" \
    && printf '%s' "$out" | grep -q '"id": "MOB-1", "repo": "", "title": "Schema", "deps": \[\], "files": \["src/db/schema.ts"\]' \
    && printf '%s' "$out" | grep -q '"id": "MOB-2", "repo": "api", "title": "Endpoint", "deps": \["MOB-1"\], "files": \["src/api/routes.ts"\]'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
  rm -rf "$dir"
}

test_closed_issues_are_not_nodes() {
  local name="completed and canceled issues are dropped, along with every dep naming them"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  cat > "$dir/page-1.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-1","title":"Done","description":"## Files\na.ts\n\n## Deps\nnone","state":{"type":"completed"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-2","title":"Dropped","description":null,"state":{"type":"canceled"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-3","title":"Open","description":"## Files\nb.ts\n\n## Deps\nMOB-1\nMOB-2\nMOB-4","state":{"type":"started"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-4","title":"Root","description":"## Files\nc.ts","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
  out="$(run_nodes "$dir" "P")"

  if ! printf '%s' "$out" | grep -q '"id": "MOB-1"' \
    && ! printf '%s' "$out" | grep -q '"id": "MOB-2"' \
    && printf '%s' "$out" | grep -q '"id": "MOB-3", .*"deps": \["MOB-4"\]' \
    && printf '%s' "$out" | grep -q '"id": "MOB-4", .*"deps": \[\], "files": \["c.ts"\]'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
  rm -rf "$dir"
}

test_native_blocked_by_becomes_a_dep() {
  local name="a native blocked-by relation is a dep, merged with ## Deps without duplicates"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  cat > "$dir/page-1.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-1","title":"A","description":"## Files\na.ts","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-2","title":"B","description":"## Files\nb.ts","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-3","title":"C","description":"## Files\nc.ts\n\n## Deps\nMOB-1","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[{"type":"blocks","issue":{"identifier":"MOB-1"}},{"type":"related","issue":{"identifier":"MOB-9"}},{"type":"blocks","issue":{"identifier":"MOB-2"}}]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
  out="$(run_nodes "$dir" "P")"

  if printf '%s' "$out" | grep -q '"id": "MOB-3", .*"deps": \["MOB-1", "MOB-2"\]'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
  rm -rf "$dir"
}

test_description_escapes_do_not_derail_the_reader() {
  local name="quotes, backslashes and sub-headings inside a description leave the next issue intact"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  cat > "$dir/page-1.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-1","title":"Uses \"quotes\" and a slash \\","description":"## Contexto\nregex `\\n` e \"aspas\" e {chaves} [colchetes], fim \\\\\n### Detalhe\nMOB-7 não é um nó\n## Files\n- modify `src/a.ts` — x\n### Notas\nsrc/not-a-file.ts\n## Deps\nnone","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-2","title":"","description":"","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
  out="$(run_nodes "$dir" "P")"

  if [ "$(printf '%s\n' "$out" | grep -c '"id":')" = "2" ] \
    && printf '%s' "$out" | grep -q '"id": "MOB-1", .*"deps": \[\], "files": \["src/a.ts"\]' \
    && printf '%s' "$out" | grep -q '"id": "MOB-2", .*"deps": \[\], "files": \[\]'; then
    log_pass "$name"
  else
    log_fail "$name (got: $out)"
  fi
  rm -rf "$dir"
}

test_output_is_accepted_by_init() {
  local name="the emitted nodes.json initializes a graph as-is"
  local dir rc=0
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  cat > "$dir/page-1.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-1","title":"Schema: \"users\"","description":"## Files\nsrc/db/schema.ts","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}},
{"identifier":"MOB-2","title":"Endpoint","description":"## Files\nsrc/api/routes.ts\n## Deps\nMOB-1","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
  (
    cd "$dir"
    git init -q .
    git config user.email t@t.com
    git config user.name t
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    run_nodes "$dir" "P" > nodes.json
    bash "$GRAPH" init --feature f --from nodes.json --driver manual --base-branch main >/dev/null
  ) || rc=$?
  local json
  json="$(cd "$dir" && bash "$GRAPH" status --json 2>/dev/null || true)"

  if [ "$rc" -eq 0 ] && printf '%s' "$json" | grep -q 'MOB-2'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc json=$json)"
  fi
  rm -rf "$dir"
}

test_missing_key_exits_4_without_calling_out() {
  local name="without LINEAR_API_KEY the command exits 4 and never reaches the network"
  local dir rc=0 err
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  err="$(FAKE_DIR="$dir" PATH="$dir/bin:$PATH" LINEAR_API_KEY="" bash "$GRAPH" nodes --from-linear "P" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 4 ] && [ ! -f "$dir/calls" ] && printf '%s' "$err" | grep -q 'LINEAR_API_KEY'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc err=$err)"
  fi
  rm -rf "$dir"
}

test_key_never_reaches_argv() {
  local name="the API key travels on stdin, never on curl's command line"
  local dir
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  cat > "$dir/page-1.json" <<'EOF'
{"data":{"issues":{"nodes":[
{"identifier":"MOB-1","title":"A","description":"## Files\na.ts","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
EOF
  run_nodes "$dir" "P" >/dev/null

  if ! grep -q 'lin_api_secret' "$dir/argv" && grep -q 'Authorization: lin_api_secret' "$dir/stdin"; then
    log_pass "$name"
  else
    log_fail "$name (argv=$(cat "$dir/argv"))"
  fi
  rm -rf "$dir"
}

test_api_error_is_surfaced() {
  local name="an error answer from Linear fails the command with Linear's own message"
  local dir rc=0 err
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  printf '%s\n' '{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}' > "$dir/page-1.json"
  err="$(run_nodes "$dir" "P" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'Authentication required'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc err=$err)"
  fi
  rm -rf "$dir"
}

test_unknown_project_is_refused() {
  local name="a project name that matches no issue fails instead of emitting an empty graph"
  local dir rc=0 err
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  printf '%s\n' '{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}' > "$dir/page-1.json"
  err="$(run_nodes "$dir" "Nope" 2>&1 >/dev/null)" || rc=$?

  if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'no issue found'; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc err=$err)"
  fi
  rm -rf "$dir"
}

test_two_hundred_large_issues_stay_fast() {
  local name="200 issues with 20 KB descriptions convert in seconds"
  local dir out start elapsed filler i p
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  filler="$(awk 'BEGIN { for (i = 0; i < 250; i++) printf "linha de critério de aceite com \\\"aspas\\\" e acentuação número %d\\n", i }')"
  i=0
  for p in 1 2 3 4; do
    {
      printf '{"data":{"issues":{"nodes":['
      local j
      for j in $(seq 1 50); do
        i=$((i + 1))
        [ "$j" -eq 1 ] || printf ','
        printf '{"identifier":"MOB-%d","title":"T %d","description":"## Contexto\\n%s## Files\\n- modify `src/m%d/file.ts` — x\\n\\n## Deps\\n%s","state":{"type":"unstarted"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}' \
          "$i" "$i" "$filler" "$i" "$([ "$i" -gt 1 ] && echo "MOB-$((i - 1))" || echo none)"
      done
      if [ "$p" -lt 4 ]; then
        printf '],"pageInfo":{"hasNextPage":true,"endCursor":"C%d"}}}}\n' "$p"
      else
        printf '],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}\n'
      fi
    } > "$dir/page-$p.json"
  done
  start="$(date +%s)"
  out="$(run_nodes "$dir" "P")"
  elapsed=$(( $(date +%s) - start ))

  if [ "$(printf '%s\n' "$out" | grep -c '"id":')" = "200" ] \
    && printf '%s' "$out" | grep -q '"id": "MOB-200", .*"deps": \["MOB-199"\], "files": \["src/m200/file.ts"\]' \
    && [ "$elapsed" -le 20 ]; then
    log_pass "$name"
  else
    log_fail "$name (nodes=$(printf '%s\n' "$out" | grep -c '"id":') elapsed=${elapsed}s)"
  fi
  rm -rf "$dir"
}

test_project_is_read_across_pages
test_closed_issues_are_not_nodes
test_native_blocked_by_becomes_a_dep
test_description_escapes_do_not_derail_the_reader
test_output_is_accepted_by_init
test_missing_key_exits_4_without_calling_out
test_key_never_reaches_argv
test_api_error_is_surfaced
test_unknown_project_is_refused
test_two_hundred_large_issues_stay_fast

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
