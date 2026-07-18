#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pipeline.sh <subcommand> [args...]" >&2
  echo "  init  <task-id> [--mode check|fresh|resume] [--config <path>]" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  init)
    exec bash "$HOOK_DIR/run-init.sh" "$@" ;;
  *)
    usage
    exit 1 ;;
esac
