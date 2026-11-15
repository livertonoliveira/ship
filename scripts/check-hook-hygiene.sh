#!/usr/bin/env bash
# Structural guards over src/hooks/*.sh — the shell hazards that have each cost
# a run, refused before they ship instead of found in one.
#
#   1. Every hook sources lib.sh right after its `set -e…` line, so a death
#      under errexit always names its line (lib.sh: ship_died).
#   2. No hook pipes into `grep -q`. Under pipefail the writer is killed by
#      SIGPIPE the moment grep finds its match and the whole pipeline reads as
#      "no match": on a 30,000-file repo `git ls-files | grep -q` answered "no
#      e2e runner" ten times out of ten. Use `grep -q … <<< "$(cmd)"`.
#   3. No hook reads JSON with sed/grep: lib.sh's json_* functions do.
#   4. shellcheck at warning level, over hooks, their tests and scripts/.
#      Skipped with a notice when shellcheck is not installed, unless
#      SHELLCHECK_REQUIRED=1 (CI sets it).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
bad() { echo "✗ $1"; fail=1; }

for f in src/hooks/*.sh; do
  [ "$(basename "$f")" = "lib.sh" ] && continue
  if ! awk '
      /^set -eu/ { getline nxt; if (nxt == ". \"$(dirname \"${BASH_SOURCE[0]}\")/lib.sh\"") ok = 1; exit }
      END { exit !ok }
    ' "$f"; then
    bad "$f does not source lib.sh on the line after its 'set -e…'"
  fi
done

hits="$(grep -nE '\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-[A-Za-z]*q' src/hooks/*.sh || true)"
if [ -n "$hits" ]; then
  bad "a hook pipes into 'grep -q' (use: grep -q … <<< \"\$(cmd)\"):"
  printf '%s\n' "$hits" | sed 's/^/    /'
fi

hits="$(grep -nE '\[\[:space:\]\]\*:\[\[:space:\]\]\*\\?"' src/hooks/*.sh | grep -vE '^src/hooks/(audit-heuristics|coverage-correlate)\.sh:' || true)"
if [ -n "$hits" ]; then
  bad "a hook matches a JSON \"key\": \"value\" with a regex (use lib.sh: json_find / json_get / json_stream):"
  printf '%s\n' "$hits" | sed 's/^/    /'
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning -x src/hooks/*.sh scripts/*.sh || fail=1
  shellcheck -S warning -e SC2010 src/hooks/tests/*.sh || fail=1
elif [ "${SHELLCHECK_REQUIRED:-0}" = "1" ]; then
  bad "shellcheck is not installed and SHELLCHECK_REQUIRED=1"
else
  echo "· shellcheck not installed — lint skipped (brew install shellcheck)"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ hook hygiene: lib.sh sourced, no pipe into grep -q, no regex over JSON, shellcheck clean"
fi
exit "$fail"
