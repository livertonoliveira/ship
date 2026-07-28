#!/usr/bin/env bash

# audit-inventory.sh [--out <file>] [--max-per-category N]
#
# One deterministic pass over the tracked file tree, classified into the
# categories the project-wide audits look for.
#
# `/ship:audit:run` on a fullstack+DB project fans out to ~5 audit workers, each
# of which spawns 2-4 sub-agents — around twenty agents, every one of them told
# to scan "the whole tree" and every one of them independently globbing and
# grepping for the same routes, services, models and tests. This file is that
# discovery, done once, by a script that does not need a model to do it.
#
# It is an INDEX, never a scope limit — the generated header says so, because an
# inventory silently treated as a denylist turns a security audit into a false
# negative. Anything a category missed is still in `## Unclassified`.

set -euo pipefail

OUT=""
MAX=200

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --max-per-category) MAX="$2"; shift 2 ;;
    -h|--help)
      echo "usage: audit-inventory.sh [--out <file>] [--max-per-category N]" >&2
      exit 0 ;;
    *) echo "audit-inventory.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$MAX" in
  *[!0-9]*|'') echo "audit-inventory.sh: --max-per-category must be an integer: $MAX" >&2; exit 1 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "audit-inventory.sh: not inside a git work tree" >&2
  exit 1
fi

FILES="$(mktemp)"
trap 'rm -f "$FILES" "$FILES".*' EXIT

# git ls-files respects .gitignore for free; the extra filter drops vendored and
# generated trees that are checked in on some projects.
git ls-files 2>/dev/null \
  | grep -vE '(^|/)(node_modules|vendor|dist|build|out|target|\.next|__pycache__|coverage)(/|$)' \
  | grep -vE '\.(min\.js|min\.css|lock|snap|png|jpe?g|gif|svg|ico|woff2?|ttf|eot|pdf|zip|gz)$' \
  | grep -vE '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Gemfile\.lock|composer\.lock)$' \
  > "$FILES" || true

# Category order matters: the first match wins, so the narrow patterns (tests,
# dependency manifests) are tested before the broad ones (services, source).
classify() {
  awk '
    {
      p = tolower($0)
      cat = "unclassified"
      # Directory names like hooks/, security/ or pages/ are ambiguous outside a
      # codebase — without this guard a repo of shell scripts and markdown lands
      # 254 files under "Frontend". Only files that are actually source get a
      # code category; the rest can still be deps, config or a test path.
      code = (p ~ /\.(js|mjs|cjs|ts|jsx|tsx|vue|svelte|py|rb|go|java|kt|rs|php|cs|swift|scala|ex|exs|c|cc|cpp|h|hpp|m|mm|sql|prisma)$/)
      if (p ~ /(^|\/)(tests?|specs?|__tests__|e2e|cypress|playwright)(\/|$)/ ||
          p ~ /\.(test|spec)\.[a-z0-9]+$/ ||
          p ~ /(^|\/)test_[^\/]*\.py$/ ||
          p ~ /_test\.(go|py|rb|js|ts)$/) cat = "tests"
      else if (p ~ /(^|\/)(package\.json|requirements\.txt|pyproject\.toml|go\.mod|gemfile|pom\.xml|build\.gradle|cargo\.toml|composer\.json|pubspec\.yaml)$/) cat = "deps"
      else if (code && (p ~ /(^|\/)(migrations?|migrate)(\/|$)/ ||
                        p ~ /(^|\/)(models?|entities|schemas?|repositor(y|ies)|dao)(\/|$)/ ||
                        p ~ /\.(sql|prisma)$/ ||
                        p ~ /(schema|model|entity|repository)\.[a-z0-9]+$/)) cat = "data"
      else if (code && (p ~ /(^|\/)(routes?|controllers?|handlers?|endpoints?|api|resolvers?)(\/|$)/ ||
                        p ~ /(route|controller|handler|resolver)\.[a-z0-9]+$/ ||
                        p ~ /(^|\/)(app|pages)\/.*\/(route|page)\.[a-z0-9]+$/)) cat = "entrypoints"
      else if (code && (p ~ /(^|\/)(middlewares?|guards?|auth|security|policies)(\/|$)/ ||
                        p ~ /(middleware|guard|policy)\.[a-z0-9]+$/)) cat = "auth"
      else if (p ~ /\.(jsx|tsx|vue|svelte)$/ ||
               (code && p ~ /(^|\/)(components?|views?|screens?|widgets?)(\/|$)/)) cat = "frontend"
      else if (code && (p ~ /(^|\/)(services?|usecases?|use_cases|domain|business|jobs?|workers?)(\/|$)/ ||
                        p ~ /(service|usecase|job|worker)\.[a-z0-9]+$/)) cat = "services"
      else if (p ~ /(^|\/)(config|configs|settings|infra|infrastructure|deploy|\.github|\.circleci)(\/|$)/ ||
               p ~ /(^|\/)(dockerfile|docker-compose\.ya?ml|makefile)$/ ||
               p ~ /\.(env|ini|toml|cfg|conf)$/ ||
               p ~ /(config|settings)\.[a-z0-9]+$/) cat = "config"
      else if (code) cat = "source"
      print cat "\t" $0
    }
  ' "$FILES"
}

classify > "$FILES.classified"

section() {
  local key="$1" title="$2" hint="$3" n shown
  n="$(awk -F'\t' -v k="$key" '$1 == k' "$FILES.classified" | wc -l | tr -d ' ')"
  printf '\n## %s (%s)\n\n' "$title" "$n"
  if [ "$n" -eq 0 ]; then
    printf '_none found_\n'
    return 0
  fi
  [ -n "$hint" ] && printf '%s\n\n' "$hint"
  # Limiting inside awk, not through `head` — closing the pipe early kills awk
  # with SIGPIPE, which `set -o pipefail` turns into an aborted run.
  awk -F'\t' -v k="$key" -v m="$MAX" '$1 == k && ++c <= m { print "- " $2 }' "$FILES.classified"
  shown="$MAX"
  [ "$n" -lt "$MAX" ] && shown="$n"
  if [ "$n" -gt "$MAX" ]; then
    printf '\n_%s of %s shown — this category was truncated at --max-per-category; enumerate the rest yourself before concluding coverage._\n' "$shown" "$n"
  fi
}

render() {
  printf '# Audit Inventory\n\n'
  printf 'Deterministic index of the tracked file tree, produced once by\n'
  printf '`audit-inventory.sh` so each audit agent can skip its own discovery pass.\n\n'
  printf '**This is an index, not a scope limit.** A file being absent from a category\n'
  printf 'means the path heuristics did not recognize it, never that it is out of scope.\n'
  printf 'Start from the relevant sections, then widen with your own search wherever the\n'
  printf 'audit needs it — `## Unclassified` in particular is unreviewed leftovers.\n'
  printf '\nTotal tracked files considered: %s\n' "$(wc -l < "$FILES" | tr -d ' ')"

  section entrypoints "Entrypoints" "Routes, controllers, handlers, resolvers — request surface."
  section services    "Services" "Business logic, use cases, jobs, workers."
  section data        "Data access" "Models, schemas, repositories, migrations, SQL."
  section auth        "Auth and middleware" "Guards, policies, middleware — access control surface."
  section frontend    "Frontend" "Components, pages, hooks, view-layer files."
  section config      "Config and infrastructure" "Config, env, CI, container and deploy files."
  section deps        "Dependency manifests" "Where third-party versions are declared."
  section tests       "Tests" "Existing test and spec files, all layers."
  section source      "Other source" "Source files no narrower category claimed."
  section unclassified "Unclassified" "Everything else — docs, data, unrecognized extensions."
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  render > "$OUT"
  printf 'inventory=%s\n' "$OUT"
else
  render
fi
