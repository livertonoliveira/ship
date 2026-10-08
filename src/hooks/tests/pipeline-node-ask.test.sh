#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="$SCRIPT_DIR/../pipeline.sh"

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

setup_repo() {
  local dir="$1"
  (
    cd "$dir"
    git init -q .
    git config user.email test@test.com
    git config user.name test
    printf 'x\n' > f.txt
    git add f.txt
    git commit -qm init
    git branch -M main
    git update-ref refs/remotes/origin/main HEAD
    mkdir -p ship
    printf '# Ship Config\n\n## Pipeline Phases\n- dev: disabled\n- test: disabled\n- perf: disabled\n- security: disabled\n- review: disabled\n- homolog: enabled\n\n## Conventions\n- Artifact language: English\n' > ship/config.md
    bash "$PIPELINE" next T-1 >/dev/null 2>&1 || true
    printf '# Spec\n\nfixture.\n' > .context/ship-run/T-1/spec.md
    printf '# Design\n\nnone.\n' > .context/ship-run/T-1/design.md
  )
}

test_ask_posts_the_question_where_the_graph_reads_it() {
  local name="a node's own question lands in ask.md, the file graph.sh next collects"
  local dir out
  dir="$(mktemp -d)"; setup_repo "$dir"
  out="$(cd "$dir" && bash "$PIPELINE" ask T-1 "Delete the dead export, or ignore it in knip?")"
  if [ "$(field "$out" posted)" = "1" ] \
     && grep -q '^question=Delete the dead export, or ignore it in knip?$' "$dir/.context/ship-run/T-1/ask.md" \
     && printf '%s' "$out" | grep -q 'wait-answer T-1'; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
  rm -rf "$dir"
}

test_next_does_not_advance_over_an_unanswered_question() {
  local name="next keeps the node waiting, and the question posted, until it is answered"
  local dir out
  dir="$(mktemp -d)"; setup_repo "$dir"
  (cd "$dir" && bash "$PIPELINE" ask T-1 "which one?" >/dev/null)
  out="$(cd "$dir" && bash "$PIPELINE" next T-1)"
  if [ "$(field "$out" state)" = "waiting" ] && [ -f "$dir/.context/ship-run/T-1/ask.md" ] \
     && printf '%s' "$out" | grep -q 'which one?'; then
    log_pass "$name"
  else
    log_fail "$name (out: $out)"
  fi
  rm -rf "$dir"
}

test_the_answer_reaches_the_node_and_never_a_gate() {
  local name="the answer comes back through wait-answer and is not fed to a gate as --answer"
  local dir waited out s
  dir="$(mktemp -d)"; setup_repo "$dir"
  s="$dir/.context/ship-run/T-1"
  (cd "$dir" && bash "$PIPELINE" ask T-1 "approve the deletion?" >/dev/null)
  # What graph.sh answer does: write the answer, drop the question.
  printf 'approved\n' > "$s/answer.txt"; rm -f "$s/ask.md"
  waited="$(cd "$dir" && bash "$PIPELINE" wait-answer T-1 --timeout 5)"
  out="$(cd "$dir" && bash "$PIPELINE" next T-1)"
  # `approved` is also the homolog token: fed to the gate it would approve the
  # task. The pipeline must still stop at homolog for its own acceptance.
  if [ "$(field "$waited" answered)" = "1" ] && [ "$(field "$waited" answer)" = "approved" ] \
     && [ "$(field "$out" state)" = "homolog" ] && [ ! -f "$s/homolog-approved.txt" ] \
     && [ ! -f "$s/node-question.txt" ] && [ ! -f "$s/answer.txt" ]; then
    log_pass "$name"
  else
    log_fail "$name (waited: $waited / state=$(field "$out" state))"
  fi
  rm -rf "$dir"
}

test_ask_posts_the_question_where_the_graph_reads_it
test_next_does_not_advance_over_an_unanswered_question
test_the_answer_reaches_the_node_and_never_a_gate

echo
echo "$pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
