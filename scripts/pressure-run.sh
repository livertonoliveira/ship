#!/usr/bin/env bash

set -uo pipefail

usage() {
  echo "usage: pressure-run.sh <caso> [--record|--replay] [--reps N]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

CASE_NAME="$1"
shift

MODE="--replay"
REPS_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --record)
      MODE="--record"
      shift
      ;;
    --replay)
      MODE="--replay"
      shift
      ;;
    --reps)
      if [ $# -lt 2 ]; then
        usage
        exit 1
      fi
      REPS_OVERRIDE="$2"
      if ! [[ "$REPS_OVERRIDE" =~ ^[0-9]+$ ]] || [ "$REPS_OVERRIDE" -lt 1 ]; then
        echo "pressure-run: --reps must be a positive integer: $REPS_OVERRIDE" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESSURE_CORE="$REPO_ROOT/plugins/ship/scripts/pressure"
CASE_DIR="$REPO_ROOT/pressure/cases/$CASE_NAME"

if [ ! -d "$CASE_DIR" ] || [ ! -f "$CASE_DIR/case.json" ]; then
  echo "pressure-run: case not found: $CASE_DIR" >&2
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "pressure-run: node not found on PATH" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BRIDGE="$TMP/bridge.js"
cat > "$BRIDGE" <<NODEEOF
'use strict';
const path = require('node:path');
const core = require('$PRESSURE_CORE/cases.js');
const { runAssertion } = require('$PRESSURE_CORE/assert.js');
const { aggregate } = require('$PRESSURE_CORE/aggregate.js');
const { renderMarkdown } = require('$PRESSURE_CORE/report.js');
const { exitCodeFor } = require('$PRESSURE_CORE/outcomes.js');

const mode = process.argv[2];
const caseDir = process.argv[3];
const caseName = process.argv[4];

if (mode === 'meta') {
  try {
    const meta = core.loadCase(caseDir);
    const anchor =
      meta.arms && meta.arms.control && typeof meta.arms.control.anchor === 'string'
        ? meta.arms.control.anchor
        : '';
    process.stdout.write([meta.skill, meta.input, String(meta.reps), anchor].join('\n') + '\n');
  } catch (err) {
    process.stderr.write(String((err && err.message) || err) + '\n');
    process.exit(1);
  }
} else if (mode === 'replay') {
  try {
    const meta = core.loadCase(caseDir);
    const results = [];
    for (const arm of ['treatment', 'control']) {
      const reps = core.listReps(caseDir, arm);
      for (const repPath of reps) {
        const repId = path.basename(repPath);
        const artifacts = core.repArtifacts(caseDir, arm, repId);
        for (const assertionName of meta.assertions) {
          const result = runAssertion(assertionName, artifacts, meta);
          result.arm = arm;
          results.push(result);
        }
      }
    }
    const byCase = { [caseName]: aggregate(results) };
    process.stdout.write(renderMarkdown(byCase) + '\n');
    process.exit(exitCodeFor([{ case: caseName, malformed: false }]));
  } catch (err) {
    process.stderr.write(String((err && err.message) || err) + '\n');
    process.exit(exitCodeFor([{ case: caseName, malformed: true }]));
  }
} else {
  process.stderr.write('unknown bridge mode: ' + mode + '\n');
  process.exit(1);
}
NODEEOF

META_OUT="$TMP/meta.out"
META_ERR="$TMP/meta.err"
node "$BRIDGE" meta "$CASE_DIR" "$CASE_NAME" >"$META_OUT" 2>"$META_ERR"
META_STATUS=$?
if [ "$META_STATUS" -ne 0 ]; then
  echo "pressure-run: invalid case.json: $(cat "$META_ERR")" >&2
  exit 1
fi

SKILL="$(sed -n '1p' "$META_OUT")"
CASE_INPUT="$(sed -n '2p' "$META_OUT")"
CASE_REPS="$(sed -n '3p' "$META_OUT")"
CONTROL_ANCHOR="$(sed -n '4p' "$META_OUT")"

if [ ! -f "$REPO_ROOT/src/skills/$SKILL/SKILL.md" ]; then
  echo "pressure-run: skill not found: $SKILL" >&2
  exit 1
fi

run_replay() {
  local status=0
  node "$BRIDGE" replay "$CASE_DIR" "$CASE_NAME" || status=$?
  return "$status"
}

if [ "$MODE" = "--replay" ]; then
  run_replay
  exit $?
fi

EFFECTIVE_REPS="$CASE_REPS"
if [ -n "$REPS_OVERRIDE" ]; then
  EFFECTIVE_REPS="$REPS_OVERRIDE"
fi

if [ ! -f "$CASE_DIR/$CASE_INPUT" ]; then
  echo "pressure-run: input file not found: $CASE_DIR/$CASE_INPUT" >&2
  exit 1
fi

INPUT_TEXT="$(cat "$CASE_DIR/$CASE_INPUT")"

PRESSURE_DRIVER="${PRESSURE_DRIVER:-claude}"
command -v "$PRESSURE_DRIVER" >/dev/null 2>&1 || {
  echo "pressure-run: driver not found on PATH: $PRESSURE_DRIVER" >&2
  exit 1
}

TO=""
if command -v timeout >/dev/null 2>&1; then
  TO="timeout 1200"
elif command -v gtimeout >/dev/null 2>&1; then
  TO="gtimeout 1200"
fi

TREATMENT_PLUGIN_DIR="$REPO_ROOT/plugins/ship"
if [ -f "$TREATMENT_PLUGIN_DIR/package.json" ]; then
  ( cd "$TREATMENT_PLUGIN_DIR" && npm run build >/dev/null 2>&1 ) || {
    echo "pressure-run: treatment plugin build failed" >&2
    exit 1
  }
fi

CONTROL_PLUGIN_DIR="$TMP/control-plugin"
CONTROL_BUILD_SCRIPT="$REPO_ROOT/scripts/pressure-control-build.sh"
if ! "$CONTROL_BUILD_SCRIPT" "$SKILL" "$CONTROL_ANCHOR" "$CONTROL_PLUGIN_DIR" >&2; then
  echo "pressure-run: control plugin build failed" >&2
  exit 1
fi

record_rep() {
  local arm="$1" rep_id="$2" plugin_dir="$3"
  local rep_dir="$CASE_DIR/arms/$arm/$rep_id"
  local work_dir
  work_dir="$(mktemp -d)"
  local driver_log="$work_dir/.pressure-driver.log"

  if ! ( cd "$work_dir" && $TO "$PRESSURE_DRIVER" --print --plugin-dir "$plugin_dir" "/ship:$SKILL $INPUT_TEXT" ) >"$driver_log" 2>&1; then
    echo "pressure-run: driver failed for arm=$arm rep=$rep_id" >&2
    cat "$driver_log" >&2
    rm -rf "$work_dir"
    return 1
  fi

  mkdir -p "$rep_dir"
  [ -f "$work_dir/plan.md" ] && cp "$work_dir/plan.md" "$rep_dir/plan.md"
  [ -d "$work_dir/code" ] && cp -R "$work_dir/code" "$rep_dir/code"
  [ -f "$work_dir/phase-status.md" ] && cp "$work_dir/phase-status.md" "$rep_dir/phase-status.md"
  rm -rf "$work_dir"
}

for ARM in treatment control; do
  if [ "$ARM" = "control" ]; then
    PLUGIN_DIR="$CONTROL_PLUGIN_DIR"
  else
    PLUGIN_DIR="$TREATMENT_PLUGIN_DIR"
  fi

  REP=1
  while [ "$REP" -le "$EFFECTIVE_REPS" ]; do
    REP_ID="$(printf 'rep-%02d' "$REP")"
    record_rep "$ARM" "$REP_ID" "$PLUGIN_DIR" || exit 1
    REP=$((REP + 1))
  done
done

run_replay
exit $?
