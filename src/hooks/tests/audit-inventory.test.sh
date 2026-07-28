#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$SCRIPT_DIR/../audit-inventory.sh"

pass_count=0
fail_count=0

log_pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
log_fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

make_repo() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git config user.email t@t
    git config user.name t
    local f
    for f in "$@"; do
      mkdir -p "$(dirname "$f")"
      printf 'x\n' > "$f"
    done
    git add -A
    git commit -qm init
  ) >/dev/null
}

# The category a path landed in, or empty.
category_of() {
  local out="$1" path="$2"
  awk -v p="- $path" '
    /^## / { cat = $0; sub(/^## /, "", cat); sub(/ \([0-9]+\)$/, "", cat) }
    $0 == p { print cat; exit }
  ' "$out"
}

assert_category() {
  local name="$1" out="$2" path="$3" expected="$4" got
  got="$(category_of "$out" "$path")"
  if [ "$got" = "$expected" ]; then
    log_pass "$name"
  else
    log_fail "$name (got '$got', expected '$expected')"
  fi
}

test_backend_tree_classification() {
  local d; d="$(mktemp -d)"
  make_repo "$d" \
    src/routes/users.ts \
    src/services/billing.service.ts \
    src/models/user.model.ts \
    src/middleware/auth.ts \
    src/components/Button.tsx \
    src/util.ts \
    package.json \
    Dockerfile \
    src/services/billing.service.test.ts \
    docs/guide.md
  local out="$d/inv.md"
  (cd "$d" && bash "$INVENTORY" --out inv.md) >/dev/null

  assert_category "a route file lands under Entrypoints" "$out" "src/routes/users.ts" "Entrypoints"
  assert_category "a service file lands under Services" "$out" "src/services/billing.service.ts" "Services"
  assert_category "a model file lands under Data access" "$out" "src/models/user.model.ts" "Data access"
  assert_category "a middleware file lands under Auth and middleware" "$out" "src/middleware/auth.ts" "Auth and middleware"
  assert_category "a .tsx file lands under Frontend" "$out" "src/components/Button.tsx" "Frontend"
  assert_category "an unremarkable source file lands under Other source" "$out" "src/util.ts" "Other source"
  assert_category "package.json lands under Dependency manifests" "$out" "package.json" "Dependency manifests"
  assert_category "a Dockerfile lands under Config and infrastructure" "$out" "Dockerfile" "Config and infrastructure"
  assert_category "a .test.ts file lands under Tests, not Services" "$out" "src/services/billing.service.test.ts" "Tests"
  assert_category "a markdown doc lands under Unclassified" "$out" "docs/guide.md" "Unclassified"
  rm -rf "$d"
}

test_non_source_paths_do_not_get_code_categories() {
  local name="ambiguous directory names on non-source files do not fake a code category"
  local d; d="$(mktemp -d)"
  # A shell/markdown repo whose directories are named hooks/, security/, pages/ —
  # the shape that put 254 markdown files under "Frontend" before the guard.
  make_repo "$d" \
    src/hooks/pipeline.sh \
    src/skills/security/SKILL.md \
    src/pages/overview.md
  local out="$d/inv.md"
  (cd "$d" && bash "$INVENTORY" --out inv.md) >/dev/null
  if [ "$(category_of "$out" src/hooks/pipeline.sh)" = "Unclassified" ] \
    && [ "$(category_of "$out" src/skills/security/SKILL.md)" = "Unclassified" ] \
    && [ "$(category_of "$out" src/pages/overview.md)" = "Unclassified" ]; then
    log_pass "$name"
  else
    log_fail "$name (hooks=$(category_of "$out" src/hooks/pipeline.sh) security=$(category_of "$out" src/skills/security/SKILL.md))"
  fi
  rm -rf "$d"
}

test_generated_and_vendored_trees_are_excluded() {
  local name="node_modules, dist and lockfiles never reach the inventory"
  local d; d="$(mktemp -d)"
  make_repo "$d" \
    node_modules/lib/index.js \
    dist/bundle.js \
    package-lock.json \
    src/app.ts
  local out="$d/inv.md"
  (cd "$d" && bash "$INVENTORY" --out inv.md) >/dev/null
  if ! grep -q 'node_modules' "$out" && ! grep -q 'dist/bundle.js' "$out" \
    && ! grep -q 'package-lock.json' "$out" \
    && grep -q -- '- src/app.ts' "$out"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$d"
}

test_header_states_it_is_not_a_scope_limit() {
  local name="the artifact itself carries the index-not-a-denylist warning"
  local d; d="$(mktemp -d)"
  make_repo "$d" src/app.ts
  local out="$d/inv.md"
  (cd "$d" && bash "$INVENTORY" --out inv.md) >/dev/null
  # This warning lives in the generated file rather than in each audit SKILL:
  # an inventory read as an allowlist turns a security audit into a false negative.
  if grep -q 'index, not a scope limit' "$out"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$d"
}

test_truncation_is_announced() {
  local name="a truncated category says so instead of silently reporting fewer files"
  local d; d="$(mktemp -d)"
  local files=() i
  for i in $(seq 1 12); do files+=("src/mod$i.ts"); done
  make_repo "$d" "${files[@]}"
  local out="$d/inv.md"
  (cd "$d" && bash "$INVENTORY" --out inv.md --max-per-category 5) >/dev/null
  if grep -q '5 of 12 shown' "$out" && grep -q 'truncated' "$out"; then
    log_pass "$name"
  else
    log_fail "$name"
  fi
  rm -rf "$d"
}

test_outside_a_git_tree_fails_loudly() {
  local name="running outside a git work tree exits non-zero instead of emitting an empty inventory"
  local d rc=0
  d="$(mktemp -d)"
  (cd "$d" && bash "$INVENTORY" >/dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_pass "$name"
  else
    log_fail "$name (rc=$rc)"
  fi
  rm -rf "$d"
}

test_backend_tree_classification
test_non_source_paths_do_not_get_code_categories
test_generated_and_vendored_trees_are_excluded
test_header_states_it_is_not_a_scope_limit
test_truncation_is_announced
test_outside_a_git_tree_fails_loudly

echo ""
echo "$pass_count passed, $fail_count failed"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
