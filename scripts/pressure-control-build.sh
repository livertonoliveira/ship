#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pressure-control-build.sh <skill> <anchor> <out-plugin-dir>" >&2
}

if [ $# -ne 3 ]; then
  usage
  exit 1
fi

SKILL="$1"
ANCHOR="$2"
OUT_PLUGIN_DIR="$3"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_SKILL_FILE="$REPO_ROOT/src/skills/$SKILL/SKILL.md"
BUILD_SCRIPT="$REPO_ROOT/plugins/ship/scripts/build.js"

if [ ! -f "$SRC_SKILL_FILE" ]; then
  echo "pressure-control-build: skill not found: $SRC_SKILL_FILE" >&2
  exit 1
fi

if [ ! -f "$BUILD_SCRIPT" ]; then
  echo "pressure-control-build: build script not found: $BUILD_SCRIPT" >&2
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "pressure-control-build: node not found on PATH" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cp -R "$REPO_ROOT/src" "$TMP/src"
mkdir -p "$TMP/plugins/ship"
cp -R "$REPO_ROOT/plugins/ship/scripts" "$TMP/plugins/ship/scripts"

TARGET_FILE="$TMP/src/skills/$SKILL/SKILL.md"
FLAG_FILE="$TMP/.anchor-found"
: > "$FLAG_FILE"

awk -v anchor="$ANCHOR" -v flagfile="$FLAG_FILE" '
{
  n = 0
  while (substr($0, n + 1, 1) == "#") { n++ }
  is_heading = (n >= 1 && n <= 6 && substr($0, n + 1, 1) == " ")

  if (is_heading) {
    if (removing && n <= level) {
      removing = 0
    }
    heading_text = substr($0, n + 2)
    if (!removing && heading_text == anchor) {
      removing = 1
      level = n
      print "1" > flagfile
      next
    }
  }

  if (removing) next
  print
}
' "$TARGET_FILE" > "$TARGET_FILE.stripped"

if [ ! -s "$FLAG_FILE" ]; then
  echo "pressure-control-build: anchor not found in $SKILL/SKILL.md: $ANCHOR" >&2
  exit 1
fi

mv "$TARGET_FILE.stripped" "$TARGET_FILE"

BUILD_LOG="$TMP/build.log"
if ! node "$TMP/plugins/ship/scripts/build.js" >"$BUILD_LOG" 2>&1; then
  echo "pressure-control-build: build failed" >&2
  cat "$BUILD_LOG" >&2
  exit 1
fi

COMPILED_FILE="$TMP/plugins/ship/skills/$SKILL/SKILL.md"
if [ ! -f "$COMPILED_FILE" ]; then
  echo "pressure-control-build: build did not produce $COMPILED_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_PLUGIN_DIR"
cp "$COMPILED_FILE" "$OUT_PLUGIN_DIR/SKILL.md"

echo "pressure-control-build: control plugin generated at $OUT_PLUGIN_DIR/SKILL.md"
