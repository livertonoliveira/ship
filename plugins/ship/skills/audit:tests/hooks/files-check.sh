#!/usr/bin/env bash
set -euo pipefail

# The `## Files` format gate, run at spec time: one verb and one path per entry.
#
#   - create|modify|delete <path> — <intent>
#
# Every parser downstream (plan-scaffold.sh, plan-validate.sh, the graph's
# footprint) reads the first word after the verb as the path. A set described
# by a count ("modify ~67 arquivos em src/"), several paths on one line
# ("modify a.tsx, b.test.tsx") or an entry with no verb produced an inventory
# row no module could claim, and a node failed plan validation on every
# attempt (MOB-8114 and MOB-8123, 2026-10-15). Caught here, before the issue
# exists, the fix is a line in the draft; caught there, it is a spent node.
#
# Brace groups are fine (files-expand.sh expands them for every reader).
# Prints one violation per line as <file>:<line>: <kind>: <entry>; exit 1 when
# there is any, else `ok files=<n> entries=<m>`.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: files-check.sh --issues <dir|files...> | --tasks <file>" >&2
}

targets=()
while [ $# -gt 0 ]; do
  case "$1" in
    --issues|--tasks)
      shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do targets+=("$1"); shift; done ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
[ "${#targets[@]}" -gt 0 ] || { usage; exit 1; }

files=()
for t in "${targets[@]}"; do
  if [ -d "$t" ]; then
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(find "$t" -type f -name '*.md' | sort)
  elif [ -f "$t" ]; then
    files+=("$t")
  fi
done

violations=0
entries=0
for f in "${files[@]}"; do
  out="$(bash "$HOOK_DIR/files-expand.sh" "$f" | awk -v file="$f" '
    /^##+[[:space:]]+Files([^[:alnum:]_]|$)/ { insection = 1; next }
    /^#+[[:space:]]/ { insection = 0 }
    insection && /^[[:space:]]*[-*][[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
      gsub(/`/, "", line)
      gsub(/\\/, "", line)
      if (line ~ /^(Âncora|Ancora|Anchor)[[:space:]]*:/) next
      entries++
      if (!match(line, /^(create|modify|delete)[[:space:]]+/)) {
        printf "%s:%d: no-verb: %s\n", file, NR, line; bad++; next
      }
      rest = substr(line, RLENGTH + 1)
      sub(/^[A-Za-z0-9._-]+:[[:space:]]+/, "", rest)
      head = rest
      sub(/[[:space:]]*(—|–|--).*$/, "", head)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", head)
      if (head ~ /,/) { printf "%s:%d: several-paths: %s\n", file, NR, line; bad++; next }
      if (head ~ /[[:space:]]/) { printf "%s:%d: not-a-path: %s\n", file, NR, line; bad++; next }
      if (head !~ /\// && head !~ /\.[A-Za-z0-9]+$/) { printf "%s:%d: not-a-path: %s\n", file, NR, line; bad++; next }
      if (head ~ /[,;:]$/) { printf "%s:%d: trailing-punct: %s\n", file, NR, line; bad++; next }
    }
    END { printf "__entries=%d __bad=%d\n", entries + 0, bad + 0 }
  ')"
  summary="$(printf '%s\n' "$out" | grep '^__entries=' || true)"
  printf '%s\n' "$out" | grep -v '^__entries=' || true
  e="$(printf '%s' "$summary" | sed -E 's/.*__entries=([0-9]+).*/\1/')"
  b="$(printf '%s' "$summary" | sed -E 's/.*__bad=([0-9]+).*/\1/')"
  entries=$((entries + ${e:-0}))
  violations=$((violations + ${b:-0}))
done

if [ "$violations" -gt 0 ]; then
  echo "files-check: $violations violation(s) — one verb and one path per entry: create|modify|delete <path> — <intent>" >&2
  exit 1
fi
printf 'ok files=%s entries=%s\n' "${#files[@]}" "$entries"
