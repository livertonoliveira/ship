#!/usr/bin/env bash

# deidentify.sh [--team <KEY>] [--key <KEY-123>] < context > clean-context
#
# Strips spec identifiers from context that is about to be injected into a test
# worker's prompt: what a worker never sees, it cannot echo into a test name.
#
#   - tag-only lines (a scenario tag plus a layer tag) are dropped
#   - inline tags: @SC-/@AC-/@REQ-<n>, @unit/@integration/@e2e
#   - bare ids: REQ-/AC-/SC-<n>, IMPL-*/TEST-*, with the separator that follows
#     them, and a parenthesised id with its parentheses
#   - the Linear issue key: --key strips that literal key, --team every <TEAM>-<n>
#
# Everything else is kept verbatim — scenario titles, Given/When/Then steps,
# Examples tables — because that is the behavior the worker tests. Generic
# `WORD-<n>` tokens are left alone (UTF-8, ISO-8601) unless --team names them.

set -euo pipefail

TEAM=""
KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    -h|--help)
      echo "usage: deidentify.sh [--team <KEY>] [--key <KEY-123>] < context > clean-context" >&2
      exit 0 ;;
    *) echo "deidentify.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$TEAM" in
  ''|[A-Za-z][A-Za-z0-9]*) ;;
  *) echo "deidentify.sh: --team must be alphanumeric: $TEAM" >&2; exit 1 ;;
esac
case "$KEY" in
  ''|[A-Za-z][A-Za-z0-9]*-[0-9]*) ;;
  *) echo "deidentify.sh: --key must look like ABC-123: $KEY" >&2; exit 1 ;;
esac

SEP='[[:space:]]*(:|—|–|-)?[[:space:]]*'
ID='((REQ|AC|SC)-[0-9]+|(IMPL|TEST)-[A-Z0-9-]*[A-Z0-9])'

script="
/^[[:space:]]*(@[A-Za-z0-9_-]+[[:space:]]*)+\$/d
s/@(SC|AC|REQ)-[0-9]+//g
s/@(unit|integration|e2e)([^A-Za-z0-9_-]|\$)/\\2/g
s/[[:space:]]*\\(\\*?\\*?$ID\\*?\\*?\\)//g
s/\\*\\*$ID\\*\\*$SEP//g
s/(^|[^A-Za-z0-9_])$ID$SEP/\\1/g
"
if [ -n "$KEY" ]; then
  script="$script
s/[[:space:]]*\\($KEY\\)//g
s/(^|[^A-Za-z0-9_])$KEY$SEP/\\1/g
"
fi
if [ -n "$TEAM" ]; then
  script="$script
s/[[:space:]]*\\($TEAM-[0-9]+\\)//g
s/(^|[^A-Za-z0-9_])$TEAM-[0-9]+$SEP/\\1/g
"
fi

sed -E "$script"
