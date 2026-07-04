#!/usr/bin/env bash
# Ship hygiene scan — deterministic detector for spec IDs and comments in code/test files.
#
# Two modes:
#   1. Hook mode (default): reads a PostToolUse JSON event on stdin, extracts the written
#      file path, and scans that single file. On violation, prints the file:line hits to
#      stderr and exits 2 so Claude Code blocks the turn and feeds the reason back to the
#      model — which then renames the identifier / removes the comment (semantic fix the
#      script cannot do deterministically). Exit 0 = clean (turn proceeds).
#   2. Sweep mode (--all): scans the whole working tree (tracked + untracked) for the same
#      violations and prints them. Used for retroactive cleanup of files written before the
#      hook existed. Always exits 0 (report-only).
#
# The script is the *tripwire*; remediation is the model's job. This is the only part of the
# hygiene gate that is genuinely deterministic — it does not depend on an LLM choosing to run.

set -euo pipefail

SPEC_RE='\b(REQ|AC|SC|IMPL|TEST)-[0-9]+\b'

# --- helpers ---------------------------------------------------------------

is_excluded() {
  # $1 = absolute or relative file path. Returns 0 (excluded) / 1 (scan it).
  local p="$1" base
  base="$(basename "$p")"
  case "$p" in
    *.md) return 0 ;;                       # specs, reports, docs — spec IDs are legitimate here
    */.context/*) return 0 ;;               # scratch dir (gitignored)
    */ship/changes/*|*/ship/audits/*) return 0 ;;
  esac
  case "$base" in
    package-lock.json|pnpm-lock.yaml|yarn.lock|go.sum|Cargo.lock|*.lock) return 0 ;;
  esac
  return 1
}

comment_pattern_for() {
  # Echoes an ERE that matches a comment marker for the file's extension, or empty if none.
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

# Build the full spec-ID regex, adding the Linear issue key derived from the current branch
# (e.g. feat/MOB-1734-foo -> \bMOB-[0-9]+\b) so dynamic keys are caught too, not just the
# fixed Ship prefixes.
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

# Comment enforcement is a Ship convention, not a universal one — applying it to every file the
# user hand-writes (shell/YAML/CI legitimately use comments) would be intrusive. So comments are
# only flagged inside an active Ship run (a `.context/ship-run/` marker dir). Spec IDs, by
# contrast, are *always* wrong in code and are flagged everywhere. (--all sweep enables both.)
comments_enabled() {
  [ "${SCAN_COMMENTS:-0}" = "1" ] && return 0
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -d "${root:-.}/.context/ship-run" ] || [ -d ".context/ship-run" ]
}

scan_file() {
  # $1 = path. Appends "path:line: <text>" hits to the global HITS array. Returns 0 if any.
  local p="$1" found=1 cre spec
  [ -f "$p" ] || return 1
  is_excluded "$p" && return 1
  spec="$(full_spec_re)"

  while IFS= read -r line; do HITS+=("$p:$line"); found=0; done < <(grep -nE "$spec" "$p" 2>/dev/null || true)

  if comments_enabled; then
    cre="$(comment_pattern_for "$p")"
    if [ -n "$cre" ]; then
      while IFS= read -r line; do
        case "$line" in 1:'#!'*) continue ;; esac   # shebang on line 1 is not a comment
        HITS+=("$p:$line"); found=0
      done < <(grep -nE "$cre" "$p" 2>/dev/null || true)
    fi
  fi
  return $found
}

# --- mode: sweep (--all) ---------------------------------------------------

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

# --- mode: hook (PostToolUse on Write/Edit) --------------------------------

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
