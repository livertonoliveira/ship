#!/usr/bin/env bash

# deps-bootstrap.sh — a fresh workspace gets its dependencies before anything
# runs in it.
#
#   deps-bootstrap.sh <scratch-dir> [--config <ship/config.md>]
#
# A graph node is a fresh checkout. Whether its dependencies are installed
# depends on the runtime that created it, not on Ship — measured live on a
# multi-repo graph (2026-10-14): every api-agendx workspace arrived with
# node_modules, every platform-agendx workspace arrived without, and the node's
# typecheck died on "Cannot find module 'vitest'" — an environment stop, two
# attempts, a node failed for a `pnpm install` that takes seven seconds.
#
# Deterministic: the lockfile names the package manager (the config's Package
# Manager is the fallback), `node_modules` with no packages means nothing was
# installed, and the install runs once per run under CI=true (no prompts) with
# the frozen lockfile. The outcome is one line in <scratch>/deps-bootstrap.txt:
#   installed=<pm>          the install ran and exited 0
#   skipped=<reason>        nothing to do (no lockfile, already installed, ...)
#   failed=<pm> exit=<n>    the install ran and failed — log in deps-bootstrap.log
# Exit 0 on installed/skipped, 1 on failed. Never runs twice for one run.

set -euo pipefail

usage() { echo "usage: deps-bootstrap.sh <scratch-dir> [--config <path>]" >&2; }

scratch="" config="ship/config.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; exit 2 ;;
    *) if [ -z "$scratch" ]; then scratch="$1"; else usage; exit 2; fi; shift ;;
  esac
done
[ -n "$scratch" ] || { usage; exit 2; }
mkdir -p "$scratch"
marker="$scratch/deps-bootstrap.txt"

if [ -f "$marker" ]; then
  cat "$marker"
  grep -q '^failed=' "$marker" && exit 1
  exit 0
fi

finish() {
  printf '%s\n' "$1" > "$marker"
  printf '%s\n' "$1"
}

field_from() {
  [ -f "$1" ] || return 0
  grep -m1 -E "^- $2:" "$1" 2>/dev/null | sed -E "s/^- $2:[[:space:]]*//" || true
}

# The lockfile is the authority; a config value written for people ("pnpm 9
# (corepack)") only breaks the tie when no lockfile is committed.
pm=""
if [ -f pnpm-lock.yaml ]; then pm=pnpm
elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then pm=npm
elif [ -f yarn.lock ]; then pm=yarn
elif [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun
elif [ -f package.json ]; then
  pm="$(field_from "$config" 'Package Manager' | awk '{ print tolower($1) }')"
  case "$pm" in npm|yarn|pnpm|bun) ;; *) pm="" ;; esac
fi

[ -n "$pm" ] || { finish "skipped=no node lockfile or package.json"; exit 0; }
command -v "$pm" >/dev/null 2>&1 || { finish "skipped=$pm not on PATH"; exit 0; }

# Installed means packages are there, not that the directory exists: a runtime
# that pre-creates node_modules leaves an empty shell behind.
if [ -d node_modules ] && [ -n "$(find node_modules -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit 2>/dev/null)" ]; then
  finish "skipped=node_modules already populated"
  exit 0
fi

case "$pm" in
  npm)  if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then cmd=(npm ci); else cmd=(npm install); fi ;;
  pnpm) cmd=(pnpm install --frozen-lockfile) ;;
  yarn) cmd=(yarn install --frozen-lockfile) ;;
  bun)  cmd=(bun install --frozen-lockfile) ;;
esac

rc=0
CI=true "${cmd[@]}" > "$scratch/deps-bootstrap.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  finish "installed=$pm"
  exit 0
fi
finish "failed=$pm exit=$rc"
exit 1
