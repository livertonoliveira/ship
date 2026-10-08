#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../node-fence.sh"

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

decide() {
  local root="$1" path="$2"
  printf '{"tool_input":{"file_path":"%s"}}' "$path" | CLAUDE_PROJECT_DIR="$root" bash "$HOOK"
}

node_ws() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/.context/ship-run/MOB-1"
  echo ".context/ship-graph/f" > "$dir/.context/ship-run/MOB-1/graph-node.txt"
  printf '%s' "$dir"
}

test_an_edit_outside_a_node_workspace_is_denied() {
  local name="inside a graph node, an edit to another checkout is denied"
  local ws out
  ws="$(node_ws)"
  out="$(decide "$ws" "/Users/someone/dev/other-repo/src/a.ts")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then log_pass "$name"; else log_fail "$name ($out)"; fi
  rm -rf "$ws"
}

test_an_edit_inside_or_to_temp_is_allowed() {
  local name="its own files, temp dirs and Claude's config stay writable"
  local ws a b c
  ws="$(node_ws)"
  a="$(decide "$ws" "$ws/src/a.ts")"
  b="$(decide "$ws" "/private/tmp/claude-501/scratch/x.md")"
  c="$(decide "$ws" "$HOME/.claude/projects/x/memory/m.md")"
  if [ -z "$a$b$c" ]; then log_pass "$name"; else log_fail "$name ($a|$b|$c)"; fi
  rm -rf "$ws"
}

test_a_session_outside_a_graph_node_is_never_fenced() {
  local name="a session whose project is not a graph node workspace is never fenced"
  local dir out
  dir="$(mktemp -d)"
  mkdir -p "$dir/.context/ship-run/MOB-1"
  out="$(decide "$dir" "/Users/someone/dev/other-repo/src/a.ts")"
  if [ -z "$out" ]; then log_pass "$name"; else log_fail "$name ($out)"; fi
  rm -rf "$dir"
}

test_an_edit_outside_a_node_workspace_is_denied
test_an_edit_inside_or_to_temp_is_allowed
test_a_session_outside_a_graph_node_is_never_fenced

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
