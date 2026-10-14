#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# spec-slice.sh — writes the run's spec.md from the issue and the Proposal, the
# slice run-scratch.md describes: the full issue, the full text of each REQ the
# issue cites, and a one-line scope index of every other REQ.
#
# Measured on platform/api-agendx nodes (2026-10-06): the orchestrator spent
# ~$0.26 a node on this step, reading the whole Proposal and Design (~16k
# tokens) into a context every later turn re-reads, to do what this script does.
#
#   spec-slice.sh <issue.md> <proposal.md> <out spec.md>
#
# A REQ block starts at a line that opens with its id ("REQ-<n> — ...") and runs
# to the next REQ line or heading. Exit 3 when the issue cites no REQ that the
# Proposal defines: the caller then stages the context the old way, so a project
# whose Proposal is shaped differently loses nothing.
# ---------------------------------------------------------------------------

# Byte mode: macOS awk cuts substr by bytes but matches regexes by character,
# and aborts on the half character a cut leaves behind.
export LC_ALL=C

issue="${1:-}" proposal="${2:-}" out="${3:-}"
if [ -z "$issue" ] || [ -z "$proposal" ] || [ -z "$out" ]; then
  echo "usage: spec-slice.sh <issue.md> <proposal.md> <out spec.md>" >&2
  exit 1
fi
[ -s "$issue" ] || { echo "spec-slice.sh: issue not found: $issue" >&2; exit 1; }
[ -s "$proposal" ] || { echo "spec-slice.sh: proposal not found: $proposal" >&2; exit 3; }

cited="$(grep -oE 'REQ-[0-9]+' "$issue" | awk '!seen[$0]++' || true)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# One record per REQ block: id, the TASK heading it sits under, its first line,
# and its full text (lines joined with \001).
awk '
  function flush() {
    if (id != "") printf "%s\t%s\t%s\t%s\n", id, task, first, text
    id = ""; text = ""
  }
  # A requirement may open as a heading ("### REQ-001 — ...") — measured on a
  # spec whose Proposal wrote every REQ that way, and whose 90 issues were all
  # staged by hand because no block ever matched.
  /^(#+[[:space:]]+)?REQ-[0-9]+[^0-9]/ {
    flush()
    line = $0
    sub(/^#+[[:space:]]+/, "", line)
    match(line, /^REQ-[0-9]+/)
    id = substr(line, 1, RLENGTH)
    first = line
    text = line
    next
  }
  /^#/ {
    flush()
    if (match($0, /TASK-[0-9]+/)) task = substr($0, RSTART, RLENGTH)
    next
  }
  id != "" { text = text "\001" $0 }
  END { flush() }
' "$proposal" > "$tmp"

# An issue that cites no requirement the Proposal defines still gets a spec:
# its own text (the ACs and scenarios live there) plus the one-line scope index
# of every REQ. Measured: a 90-issue spec keyed by audit ids, not REQs, had every
# node stage this by hand — five turns and ~60k tokens of Proposal each.
found=0
for r in $cited; do
  awk -F'\t' -v r="$r" '$1 == r { f = 1 } END { exit !f }' "$tmp" && found=1
done
[ "$found" = 1 ] || cited=""
[ -s "$tmp" ] || exit 3

{
  cat "$issue"
  printf '\n'
  for r in $cited; do
    awk -F'\t' -v r="$r" '$1 == r && !done {
      printf "## Proposal — %s\n\n", r
      n = split($4, l, "\001")
      while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print l[i]
      print ""
      done = 1
    }' "$tmp"
  done
  printf '## Scope index\n\n'
  awk -F'\t' -v cited=" $(printf '%s ' $cited)" '
    index(cited, " " $1 " ") == 0 && !seen[$1]++ {
      line = $3
      sub(/^REQ-[0-9]+[[:space:]]*(—|-|:)?[[:space:]]*/, "", line)
      if (length(line) > 70) {
        line = substr(line, 1, 70)
        sub(/[^ ]*$/, "", line)
        sub(/[ ]+$/, "", line)
        line = line "…"
      }
      printf "- %s — %s%s\n", $1, line, ($2 != "" ? " — covered by " $2 : "")
    }' "$tmp"
} > "$out"

printf 'spec=%s\n' "$out"
printf 'cited=%s\n' "$([ -n "$cited" ] && printf '%s ' $cited | sed 's/ $//' || printf 'none')"
