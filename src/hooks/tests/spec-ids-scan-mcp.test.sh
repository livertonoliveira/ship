#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/../spec-ids-scan-mcp.sh"

pass_count=0
fail_count=0

scenario_tag() {
  printf '@S''C-%s' "$1"
}

criterion_tag() {
  printf '@A''C''-%s' "$1"
}

log_pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

log_fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

hook_rc() {
  printf '%s' "$1" | bash "$SCAN" >/dev/null 2>&1
  local rc=$?
  printf '%s' "$rc"
}

hook_rc_capture() {
  printf '%s' "$1" > /tmp/__spec_ids_scan_mcp_out.$$
  local rc=0
  printf '%s' "$1" | bash "$SCAN" 2>/tmp/__spec_ids_scan_mcp_err.$$ || rc=$?
  rm -f /tmp/__spec_ids_scan_mcp_out.$$
  printf '%s' "$rc"
}

save_document_payload() {
  local content_json; content_json="$(json_escape "$1")"
  printf '{"tool_name":"mcp__linear-server__save_document","tool_input":{"title":"Spec","content":"%s"}}' "$content_json"
}

save_issue_payload() {
  local desc_json; desc_json="$(json_escape "$1")"
  printf '{"tool_name":"mcp__linear-server__save_issue","tool_input":{"title":"Issue","description":"%s"}}' "$desc_json"
}

test_reused_id_on_save_document_is_blocked() {
  local name="save_document content with one id on two behaviors is blocked"
  local body payload
  body="$(scenario_tag 25) $(criterion_tag 25) @e2e
Scenario: primeiro comportamento
  Dado a
  Quando b
  Entao c

$(scenario_tag 25) $(criterion_tag 25) @e2e
Scenario: segundo comportamento
  Dado a
  Quando b
  Entao c"
  payload="$(save_document_payload "$body")"
  if [ "$(hook_rc_capture "$payload")" = "2" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_reused_id_on_save_issue_is_blocked() {
  local name="save_issue description with one id on two behaviors is blocked"
  local body payload
  body="$(scenario_tag 30) $(criterion_tag 30) @unit
Scenario: um
  Dado a

$(scenario_tag 30) $(criterion_tag 30) @unit
Scenario: dois
  Dado a"
  payload="$(save_issue_payload "$body")"
  if [ "$(hook_rc_capture "$payload")" = "2" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_distinct_ids_pass() {
  local name="distinct ids on distinct scenarios pass"
  local body payload
  body="$(scenario_tag 25) $(criterion_tag 25) @e2e
Scenario: primeiro comportamento
  Dado a

$(scenario_tag 26) $(criterion_tag 25) @e2e
Scenario: segundo comportamento
  Dado a"
  payload="$(save_document_payload "$body")"
  if [ "$(hook_rc_capture "$payload")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_same_scenario_repeated_verbatim_passes() {
  local name="the same scenario written twice verbatim is not two behaviors"
  local body payload
  body="$(scenario_tag 25) $(criterion_tag 25) @unit
Scenario: identico
  Dado a

$(scenario_tag 25) $(criterion_tag 25) @unit
Scenario: identico
  Dado a"
  payload="$(save_document_payload "$body")"
  if [ "$(hook_rc_capture "$payload")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_unrelated_tool_is_ignored() {
  local name="a non-Linear-spec tool call is left alone"
  local payload='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  if [ "$(hook_rc_capture "$payload")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_patch_with_internal_duplicate_is_blocked() {
  local name="a patch call that introduces two behaviors under one id is blocked"
  local t1 t2 t1_json t2_json payload
  t1="
$(scenario_tag 50) $(criterion_tag 50) @unit
Scenario: primeiro
  Dado a"
  t2="
$(scenario_tag 50) $(criterion_tag 50) @unit
Scenario: segundo
  Dado a"
  t1_json="$(json_escape "$t1")"
  t2_json="$(json_escape "$t2")"
  payload="{\"tool_name\":\"mcp__linear-server__save_document\",\"tool_input\":{\"id\":\"doc-1\",\"patch\":[{\"op\":\"insert_after\",\"anchor\":\"x\",\"text\":\"${t1_json}\"},{\"op\":\"insert_after\",\"anchor\":\"y\",\"text\":\"${t2_json}\"}]}}"
  if [ "$(hook_rc_capture "$payload")" = "2" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_patch_without_duplicate_passes() {
  local name="a patch call with no internal duplicate passes"
  local payload='{"tool_name":"mcp__linear-server__save_document","tool_input":{"id":"doc-1","patch":[{"op":"replace","old_string":"foo","new_string":"bar baz"}]}}'
  if [ "$(hook_rc_capture "$payload")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_accented_content_is_parsed() {
  local name="accented Gherkin keywords are still recognized"
  local body payload
  body="$(scenario_tag 40) $(criterion_tag 40) @unit
Cenário: ação única
  Dado a"
  payload="$(save_document_payload "$body")"
  if [ "$(hook_rc_capture "$payload")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_empty_stdin_is_not_an_error() {
  local name="empty stdin exits clean"
  if [ "$(hook_rc_capture "")" = "0" ]; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
}

test_reused_id_on_save_document_is_blocked
test_reused_id_on_save_issue_is_blocked
test_distinct_ids_pass
test_same_scenario_repeated_verbatim_passes
test_unrelated_tool_is_ignored
test_patch_with_internal_duplicate_is_blocked
test_patch_without_duplicate_passes
test_accented_content_is_parsed
test_empty_stdin_is_not_an_error

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
