#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# test-regression.sh — catches the test fan-out DELETING coverage.
#
# The test worker writes whole files. When ship:develop already wrote a suite at
# the path the worker targets, "generate the contract's slots" silently becomes
# "replace what was there", and cases that existed before disappear. Observed in
# the wild: a develop-written zero-case assertion vanished, and the pipeline
# still reported the phase green because the suite it ran was the smaller one.
#
# No prose can prevent that reliably, so this measures it instead: count test
# cases per file before the fan-out, count again after, and report any file that
# lost some. A file that grew or is new is fine; only shrinkage is a regression.
#
#   test-regression.sh snapshot <out>
#   test-regression.sh check <pre> <post>   → prints "<file> <before> <after>"
#                                             exit 1 when anything shrank
# ---------------------------------------------------------------------------

usage() {
  echo "usage: test-regression.sh snapshot <out-file>" >&2
  echo "       test-regression.sh check <pre-file> <post-file>" >&2
}

# Case-declaring forms across the frameworks Ship targets. describe/context are
# deliberately absent: they group cases, they are not cases.
CASE_RE='(^|[^a-zA-Z0-9_])(it|test|scenario)[[:space:]]*\(|^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_|^[[:space:]]*func[[:space:]]+Test[A-Z]|@Test\b'

TEST_PATH_RE='(\.test\.|\.spec\.|_test\.|_spec\.|__tests__/|(^|/)tests?/|(^|/)test_[^/]*\.py)'

cmd_snapshot() {
  local out="$1" f n
  : > "$out"
  # Tracked + intent-added files only: the point is comparing the same set
  # across the fan-out, not discovering whatever the runner might glob.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    n="$(grep -cE "$CASE_RE" "$f" 2>/dev/null || true)"
    printf '%s\t%s\n' "$f" "${n:-0}" >> "$out"
  done < <(git ls-files 2>/dev/null | grep -E "$TEST_PATH_RE" || true)
  sort -o "$out" "$out"
}

cmd_check() {
  local pre="$1" post="$2"
  [ -f "$pre" ] || { echo "test-regression.sh check: pre-snapshot not found: $pre" >&2; exit 2; }
  [ -f "$post" ] || { echo "test-regression.sh check: post-snapshot not found: $post" >&2; exit 2; }

  local lost
  lost="$(awk -F'\t' '
    NR == FNR { before[$1] = $2; next }
    ($1 in before) && ($2 + 0) < (before[$1] + 0) { printf "%s %s %s\n", $1, before[$1], $2 }
  ' "$pre" "$post")"

  [ -n "$lost" ] || return 0
  printf '%s\n' "$lost"
  return 1
}

if [ $# -lt 2 ]; then
  usage
  exit 2
fi

case "$1" in
  snapshot)
    [ $# -eq 2 ] || { usage; exit 2; }
    cmd_snapshot "$2" ;;
  check)
    [ $# -eq 3 ] || { usage; exit 2; }
    cmd_check "$2" "$3" ;;
  *)
    usage; exit 2 ;;
esac
