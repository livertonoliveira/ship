#!/usr/bin/env bash

set -euo pipefail

# Prints a spec or tasks file with every brace group inside its `## Files`
# sections expanded, one line per path: `- modify src/use-{a,b}.ts — x` becomes
# `- modify src/use-a.ts — x` and `- modify src/use-b.ts — x`.
#
# Specs compress sibling files this way, and every `## Files` parser read the
# braces as one literal path. The plan scaffold then inventoried a file that
# cannot exist, the planner listed the real ones, and plan-validate rejected
# every attempt; the graph's path filter dropped the entry outright, so the
# node's conflict footprint silently lost those files. Expanding once, here,
# ahead of every parser keeps them agreeing on the same set.
#
# Expanded in awk, never by the shell: a path is spec content, and eval on it
# would run whatever the spec says. Bash semantics otherwise — nested groups
# expand, a group without a top-level comma (`{id}`) stays literal. Lines
# outside a Files section pass through untouched.

usage() {
  echo "usage: files-expand.sh <file>" >&2
}

[ $# -eq 1 ] || { usage; exit 1; }
[ -f "$1" ] || exit 0

awk '
  # Index of the brace closing the one opened at position o, or 0.
  function closing(s, o,   i, d, c) {
    d = 0
    for (i = o; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "{") d++
      else if (c == "}" && --d == 0) return i
    }
    return 0
  }
  # Appends every expansion of s to out[], from index n+1; returns the new n.
  function expand(s, out, n,   i, o, cl, inner, d, c, start, alts, k, pre, post, j) {
    for (o = index(s, "{"); o > 0; ) {
      cl = closing(s, o)
      if (cl == 0) break
      inner = substr(s, o + 1, cl - o - 1)
      k = 0; d = 0; start = 1
      for (i = 1; i <= length(inner); i++) {
        c = substr(inner, i, 1)
        if (c == "{") d++
        else if (c == "}") d--
        else if (c == "," && d == 0) { alts[++k] = substr(inner, start, i - start); start = i + 1 }
      }
      if (k > 0) {
        alts[++k] = substr(inner, start)
        pre = substr(s, 1, o - 1); post = substr(s, cl + 1)
        for (j = 1; j <= k; j++) n = expand(pre alts[j] post, out, n)
        return n
      }
      i = index(substr(s, o + 1), "{")
      o = (i > 0 ? o + i : 0)
    }
    out[++n] = s
    return n
  }
  /^#+[[:space:]]+Files([^[:alnum:]_]|$)/ { infiles = 1; print; next }
  /^#/ { infiles = 0; print; next }
  /^[[:space:]]*(-{3,}|\*{3,}|_{3,})[[:space:]]*$/ { infiles = 0; print; next }
  infiles && /\{[^}]*,/ {
    split("", got)
    m = expand($0, got, 0)
    for (x = 1; x <= m; x++) print got[x]
    next
  }
  { print }
' "$1"
