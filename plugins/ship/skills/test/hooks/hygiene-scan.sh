#!/usr/bin/env bash

set -euo pipefail

SPEC_RE='\b(REQ|AC|SC|IMPL|TEST)-[0-9]+\b'

SECRET_PROVIDER_RE='AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,48}|(sk|rk)_live_[0-9a-zA-Z]{24,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'

GENERIC_SECRET_ASSIGN_RE='(api[_-]?key|secret|token|password|passwd|credential)[^=:]{0,20}(=|:|=>)[[:space:]]*("[^"]{16,}"|'"'"'[^'"'"']{16,}'"'"')'

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

is_excluded_secrets() {
  local p="$1" base
  is_excluded "$p" && return 0
  base="$(basename "$p")"
  case "$base" in
    .env|.env.*) return 0 ;;
  esac
  return 1
}

generic_secret_hit() {
  local content="$1" lit inner lower uniq
  lit="$(printf '%s' "$content" | grep -oE '"[^"]{16,}"|'"'"'[^'"'"']{16,}'"'"'' | head -1)"
  [ -z "$lit" ] && return 1
  inner="${lit%\"}"; inner="${inner#\"}"
  inner="${inner%\'}"; inner="${inner#\'}"
  case "$inner" in
    *process.env.*|*os.environ*|*'${'*) return 1 ;;
    '<'*'>') return 1 ;;
  esac
  lower="$(printf '%s' "$inner" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *xxx*|*changeme*|*example*|*dummy*|*test*|*fake*|*your_*|*insert_*) return 1 ;;
  esac
  uniq="$(printf '%s' "$inner" | fold -w1 | sort -u | wc -l | tr -d '[:space:]')"
  [ "$uniq" = "1" ] && return 1
  return 0
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

added_lines_for() {
  local p="$1"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'ALL'; return; }
  git rev-parse --verify HEAD >/dev/null 2>&1 || { printf 'ALL'; return; }
  git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || { printf 'ALL'; return; }
  git diff -U0 HEAD -- "$p" 2>/dev/null | awk '
    /^@@/ { split($3, a, ","); ln = substr(a[1], 2) + 0; next }
    /^\+\+\+/ { next }
    /^\+/ { print ln; ln++ }
  '
}

comments_enabled() {
  [ "${SCAN_COMMENTS:-0}" = "1" ] && return 0
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -d "${root:-.}/.context/ship-run" ] || [ -d ".context/ship-run" ]
}

scan_file() {
  local p="$1" found=1 cre spec added lineno
  [ -f "$p" ] || return 1
  is_excluded "$p" && return 1
  spec="$(full_spec_re)"

  while IFS= read -r line; do HITS+=("$p:$line"); found=0; done < <(grep -nE "$spec" "$p" 2>/dev/null || true)

  if comments_enabled; then
    cre="$(comment_pattern_for "$p")"
    if [ -n "$cre" ]; then
      added="$(added_lines_for "$p")"
      if [ -n "$added" ]; then
        while IFS= read -r line; do
          case "$line" in 1:'#!'*) continue ;; esac
          if [ "$added" != "ALL" ]; then
            lineno="${line%%:*}"
            printf '%s\n' "$added" | grep -qx "$lineno" || continue
          fi
          HITS+=("$p:$line"); found=0
        done < <(grep -nE "$cre" "$p" 2>/dev/null || true)
      fi
    fi
  fi

  if ! is_excluded_secrets "$p"; then
    while IFS= read -r line; do
      HITS+=("$p:$line"); found=0; HAS_SECRET_HIT=1
    done < <(grep -nE "$SECRET_PROVIDER_RE" "$p" 2>/dev/null || true)

    while IFS= read -r line; do
      local lineno="${line%%:*}" content="${line#*:}"
      if generic_secret_hit "$content"; then
        HITS+=("$p:$lineno"); found=0; HAS_SECRET_HIT=1
      fi
    done < <(grep -inE "$GENERIC_SECRET_ASSIGN_RE" "$p" 2>/dev/null || true)
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
  HAS_SECRET_HIT=0
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
  HAS_SECRET_HIT=0
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
HAS_SECRET_HIT=0
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
    if [ "$HAS_SECRET_HIT" = "1" ]; then
      echo "- Secrets: move to an environment variable / secrets manager; rotate the credential if it was ever committed."
    fi
  } >&2
  [ -d .context/ship-run ] && touch .context/ship-run/.hygiene-hit
  exit 2
fi

exit 0
