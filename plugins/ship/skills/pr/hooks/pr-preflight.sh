#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: pr-preflight.sh [--task <task-id>] [--feature <name>] [--config <path>]" >&2
  echo "  Deterministic ship:pr prerequisites in one call: storage mode, branch state," >&2
  echo "  pending-change count, pipeline profile, local approval marker, gate row summary." >&2
  echo "Prints: storage= branch= remote= pr_base= keep_context= on_default_branch= pending_changes=" >&2
  echo "        profile= approval=" >&2
  echo "        plus one 'gate_row:' line per phase when the scratch dir exists" >&2
}

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

section_field() {
  local config="$1" section="$2" key="$3"
  [ -f "$config" ] || return 0
  awk -v h="$section" '
    $0 ~ "^## " h "$" { insection = 1; next }
    /^## / { insection = 0 }
    insection { print }
  ' "$config" | grep -m1 -E "^-[[:space:]]*$key:" | sed -E "s/^-[[:space:]]*$key:[[:space:]]*//" | awk '{print $1}' || true
}

main() {
  local task="" feature="" config="ship/config.md"

  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --feature) feature="$2"; shift 2 ;;
      --config) config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  local storage="local"
  [ "$(section_field "$config" "Linear Integration" "Configured")" = "yes" ] && storage="linear"

  local branch on_default="no"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
  case "$branch" in
    main|master) on_default="yes" ;;
  esac

  local pending
  pending="$(git status --porcelain 2>/dev/null | grep -c . || true)"

  local profile
  profile="$(section_field "$config" "Pipeline Profile" "profile")"
  profile="${profile:-standard}"

  # Local mode: the approval marker lives in the feature's report file. Linear
  # mode: approval lives in issue comments — the caller checks via MCP, so we
  # report 'unknown' rather than guess.
  local approval="unknown"
  if [ "$storage" = "local" ]; then
    approval="absent"
    local report_glob="ship/changes/$feature"
    if [ -n "$feature" ] && [ -d "$report_glob" ]; then
      if grep -rqF -- '- [x] User approves for PR' "$report_glob" 2>/dev/null; then
        approval="present"
      fi
    fi
  fi

  # "origin" is a convention, not a guarantee: a repo whose only remote carries
  # another name would have every push and every default-base lookup silently
  # aimed at a remote that does not exist.
  local remote=""
  remote="$(git config --get "branch.$branch.remote" 2>/dev/null || true)"
  if [ -z "$remote" ] && git remote get-url origin >/dev/null 2>&1; then remote="origin"; fi
  if [ -z "$remote" ] && [ "$(git remote 2>/dev/null | awk 'END { print NR + 0 }')" = "1" ]; then
    remote="$(git remote)"
  fi

  # Work-graph node: the base is the graph's base branch — the real trunk the
  # forge merges into, so the PR that lands here lands for everyone — and the
  # scratch dir must survive the run because the graph polls it to land the node.
  # Both come from the marker graph.sh claim wrote into the workspace, so the
  # skill never has to infer either.
  local pr_base="" keep_context="no"
  if [ -n "$task" ] && [ -f ".context/ship-run/$task/pr-mode.txt" ]; then
    pr_base="$(grep -m1 '^base=' ".context/ship-run/$task/pr-mode.txt" | sed 's/^base=//' || true)"
    keep_context="yes"
  fi
  if [ -z "$pr_base" ] && [ -n "$remote" ]; then
    pr_base="$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s|^$remote/||" || true)"
  fi
  [ -n "$pr_base" ] || pr_base="main"

  printf 'storage=%s\n' "$storage"
  printf 'branch=%s\n' "$branch"
  printf 'remote=%s\n' "$remote"
  printf 'pr_base=%s\n' "$pr_base"
  printf 'keep_context=%s\n' "$keep_context"
  printf 'on_default_branch=%s\n' "$on_default"
  printf 'pending_changes=%s\n' "$pending"
  printf 'profile=%s\n' "$profile"
  printf 'approval=%s\n' "$approval"

  if [ -n "$task" ] && [ -f ".context/ship-run/$task/phase-status.md" ]; then
    bash "$HOOK_DIR/pipeline.sh" rows ".context/ship-run/$task" | sed 's/^/gate_row:/'
  fi
}

main "$@"
