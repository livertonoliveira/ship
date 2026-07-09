#!/usr/bin/env bash

set -euo pipefail

SPEC_RE='\b(REQ|AC|SC|IMPL|TEST)-[0-9]+\b'

is_excluded() {
  local p="$1" base
  base="$(basename "$p")"
  case "$p" in
    *.md) return 0 ;;
    */.context/*) return 0 ;;
    */ship/changes/*|*/ship/audits/*) return 0 ;;
  esac
  case "$base" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|go.sum|Cargo.lock|*.lock) return 0 ;;
  esac
  return 1
}

comment_pattern_for() {
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.go|*.java|*.kt|*.swift|*.c|*.cpp|*.cs|*.rs|*.scala|*.php)
      printf '%s' '((^|[^:])//|/\*|\*/|^[[:space:]]*\*[[:space:]])' ;;
    *.py)        printf '%s' '(^[[:space:]]*#|[[:space:]]#|"""|'"'''"')' ;;
    *.rb|*.sh|*.bash|*.zsh|*.yaml|*.yml|*.toml|*.r)
      printf '%s' '(^[[:space:]]*#|[[:space:]]#)' ;;
    *.sql|*.lua|*.hs)  printf '%s' '(--)' ;;
    *.html|*.vue|*.svelte) printf '%s' '(<!--|-->)' ;;
    *.clj|*.lisp|*.el) printf '%s' '(;)' ;;
    *) printf '%s' '' ;;
  esac
}

full_spec_re() {
  local re="$SPEC_RE" branch key prefix
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  key="$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1 || true)"
  if [ -n "$key" ]; then
    prefix="${key%%-*}"
    case "$prefix" in REQ|AC|SC|IMPL|TEST) ;; *) re="$re|\\b${prefix}-[0-9]+\\b" ;; esac
  fi
  printf '%s' "$re"
}

comments_enabled() {
  [ "${SCAN_COMMENTS:-0}" = "1" ] && return 0
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -d "${root:-.}/.context/ship-run" ] || [ -d ".context/ship-run" ]
}

scan_file() {
  local p="$1" found=1 cre spec
  [ -f "$p" ] || return 1
  is_excluded "$p" && return 1
  spec="$(full_spec_re)"

  while IFS= read -r line; do HITS+=("$p:$line"); found=0; done < <(grep -nE "$spec" "$p" 2>/dev/null || true)

  if comments_enabled; then
    cre="$(comment_pattern_for "$p")"
    if [ -n "$cre" ]; then
      while IFS= read -r line; do
        case "$line" in 1:'#!'*) continue ;; esac
        HITS+=("$p:$line"); found=0
      done < <(grep -nE "$cre" "$p" 2>/dev/null || true)
    fi
  fi
  return $found
}

walk_dir() {
  find "$1" -type f 2>/dev/null | sort
}

if [ "${1:-}" = "--dir" ]; then
  target_dir="${2:-}"
  if [ -z "$target_dir" ] || [ ! -d "$target_dir" ]; then
    printf 'Ship hygiene — clean.\n'
    exit 0
  fi
  SCAN_COMMENTS=1
  HITS=()
  while IFS= read -r f; do [ -n "$f" ] && scan_file "$f" || true; done < <(walk_dir "$target_dir")
  if [ "${#HITS[@]}" -gt 0 ]; then
    printf 'Ship hygiene — %d hit(s) found:\n' "${#HITS[@]}"
    printf '%s\n' "${HITS[@]}"
  else
    printf 'Ship hygiene — clean.\n'
  fi
  exit 0
fi

if [ "${1:-}" = "--all" ]; then
  SCAN_COMMENTS=1
  HITS=()
  while IFS= read -r f; do [ -n "$f" ] && scan_file "$f" || true; done < <(
    { git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u
  )
  if [ "${#HITS[@]}" -gt 0 ]; then
    printf 'Ship hygiene — %d hit(s) found:\n' "${#HITS[@]}"
    printf '%s\n' "${HITS[@]}"
  else
    printf 'Ship hygiene — clean.\n'
  fi
  exit 0
fi

input="$(cat)"
file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

HITS=()
if scan_file "$file_path"; then
  {
    echo "Ship hygiene gate: forbidden content in the file you just wrote — fix it before continuing."
    echo
    echo "Violations (file:line):"
    printf '  %s\n' "${HITS[@]}"
    echo
    echo "Required fix (change NOTHING else):"
    echo "- Remove every comment of any kind (line, block, JSDoc/TSDoc, docstring, marker)."
    echo "- Strip every spec ID (REQ-/AC-/SC-/IMPL-/TEST-<n>) and Linear issue key (<PREFIX>-<n>)"
    echo "  wherever it appears — including describe/it/test names, suite/class/method names, and"
    echo "  string literals. When an ID names a test, RENAME the test to describe the behavior."
    echo "- Leave legitimate tokens that merely resemble a pattern (UTF-8, SHA-256, ISO-8601) alone."
  } >&2
  exit 2
fi

exit 0
