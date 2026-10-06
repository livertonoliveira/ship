#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINEAR="$SCRIPT_DIR/../linear.sh"

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

field() {
  printf '%s\n' "$1" | grep "^$2=" | head -1 | sed "s/^$2=//"
}

# Stands in for curl: answers by what the request asks for, records every body.
# FAKE_REPORTED is the state type the update mutation reports back.
install_fake_curl() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
body=""
for a in "$@"; do
  case "$a" in @*) body="$(cat "${a#@}")" ;; esac
done
cat > /dev/null
printf '%s\n' "$body" >> "$FAKE_DIR/bodies"
case "$body" in
  *issueUpdate*)
    printf '{"data":{"issueUpdate":{"success":true,"issue":{"state":{"name":"x","type":"%s"}}}}}' "${FAKE_REPORTED:-started}" ;;
  *team*)
    cat "$FAKE_DIR/states.json" ;;
  *)
    cat "$FAKE_DIR/context.json" ;;
esac
EOF
  chmod +x "$dir/bin/curl"
  cat > "$dir/states.json" <<'EOF'
{"data":{"issue":{"id":"uuid-1","state":{"type":"unstarted"},"team":{"states":{"nodes":[
{"id":"st-todo","name":"Todo","type":"unstarted"},
{"id":"st-review","name":"In Review","type":"started"},
{"id":"st-prog","name":"Em andamento","type":"started"},
{"id":"st-done","name":"Concluído","type":"completed"}]}}}}}
EOF
  cat > "$dir/context.json" <<'EOF'
{"data":{"issue":{"identifier":"MOB-1","title":"Trocar \"profissional\"","description":"## Contexto\nlinha um\n\tcom tab","url":"https://linear.app/x/issue/MOB-1","state":{"name":"Todo","type":"unstarted"},"project":{"name":"Platform","documents":{"nodes":[
{"title":"Design (parte 2)","content":"segunda parte do design"},
{"title":"Proposal","content":"# Proposal\nrequisitos"},
{"title":"Mapa TASK → MOB","content":"TASK-1 → MOB-1"},
{"title":"Design","content":"# Design\nprimeira parte"}]}}}}}
EOF
}

lin() {
  local dir="$1"
  shift
  FAKE_DIR="$dir" PATH="$dir/bin:$PATH" LINEAR_API_KEY="lin_api_secret" bash "$LINEAR" "$@"
}

test_without_a_key_the_caller_falls_back() {
  local name="without LINEAR_API_KEY the script exits 4 so the caller uses the MCP"
  local rc=0
  env -u LINEAR_API_KEY bash "$LINEAR" transition MOB-1 started >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 4 ]; then log_pass "$name"; else log_fail "$name (rc=$rc)"; fi
}

test_context_writes_the_issue_and_the_documents() {
  local name="context writes the issue and joins Proposal / Design parts in title order"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  out="$(lin "$dir" context MOB-1 --out "$dir/run")"
  if grep -q '^# MOB-1 — Trocar "profissional"$' "$dir/run/issue.md" \
     && grep -q "$(printf '^\tcom tab$')" "$dir/run/issue.md" \
     && grep -q '^requisitos$' "$dir/run/proposal.md" \
     && [ "$(grep -n 'primeira parte\|segunda parte' "$dir/run/design.md" | cut -d: -f2 | tr '\n' ' ')" = "primeira parte segunda parte do design " ] \
     && grep -q 'TASK-1 → MOB-1' "$dir/run/other/1.md" \
     && printf '%s' "$out" | grep -q "^design=$dir/run/design.md$"; then
    log_pass "$name"
  else
    log_fail "$name (out: $out / design: $(cat "$dir/run/design.md" 2>/dev/null))"
  fi
  rm -rf "$dir"
}

test_cached_documents_are_not_fetched_again() {
  local name="context reuses a docs dir that already holds proposal.md and design.md"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  mkdir -p "$dir/cache"
  echo cached > "$dir/cache/proposal.md"; echo cached > "$dir/cache/design.md"
  out="$(lin "$dir" context MOB-1 --out "$dir/run" --docs "$dir/cache")"
  if ! grep -q documents "$dir/bodies" && [ "$(cat "$dir/cache/design.md")" = "cached" ] \
     && printf '%s' "$out" | grep -q 'cached'; then
    log_pass "$name"
  else
    log_fail "$name (bodies: $(cat "$dir/bodies"))"
  fi
  rm -rf "$dir"
}

test_transition_prefers_the_configured_name() {
  local name="transition sets the configured state of that type, by id"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  out="$(lin "$dir" transition MOB-1 started --prefer "em andamento")"
  if [ "$(field "$out" ok)" = "1" ] && [ "$(field "$out" state)" = "Em andamento" ] \
     && grep 'issueUpdate' "$dir/bodies" | grep -q '"s":"st-prog"' \
     && grep 'issueUpdate' "$dir/bodies" | grep -q '"i":"uuid-1"'; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
  rm -rf "$dir"
}

test_transition_falls_back_to_the_type() {
  local name="an unknown configured name falls back to the first state of the type"
  local dir out
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  out="$(FAKE_REPORTED=completed lin "$dir" transition MOB-1 completed --prefer "Done")"
  if [ "$(field "$out" state)" = "Concluído" ] && grep 'issueUpdate' "$dir/bodies" | grep -q '"s":"st-done"'; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
  rm -rf "$dir"
}

test_transition_checks_what_linear_reports() {
  local name="a transition Linear does not confirm fails instead of passing silently"
  local dir rc=0
  dir="$(mktemp -d)"
  install_fake_curl "$dir"
  FAKE_REPORTED=unstarted lin "$dir" transition MOB-1 started >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then log_pass "$name"; else log_fail "$name (rc=0)"; fi
  rm -rf "$dir"
}

test_without_a_key_the_caller_falls_back
test_context_writes_the_issue_and_the_documents
test_cached_documents_are_not_fetched_again
test_transition_prefers_the_configured_name
test_transition_falls_back_to_the_type
test_transition_checks_what_linear_reports

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
