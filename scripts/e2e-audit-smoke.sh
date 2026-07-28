#!/usr/bin/env bash
# e2e-audit-smoke.sh — live, headless end-to-end smoke test of the audit suite.
#
# Sibling of e2e-smoke.sh (single-task pipeline) and e2e-graph-smoke.sh (work
# graph). This one covers the project-wide audits and, specifically, the shared
# inventory: audit-inventory.sh indexes the tree once so ~a dozen sub-agents skip
# their own discovery pass.
#
# The inventory's danger is not that it is wrong, it is that it could be read as
# a scope limit — an audit that only looks where the index points silently stops
# auditing everything else, and a security audit that does that reports clean.
# So the fixture plants a CANARY: a real vulnerability in a file the path
# heuristics deliberately cannot classify. If the audits only cover indexed
# categories, the canary survives and this test fails.
#
# Usage:
#   scripts/e2e-audit-smoke.sh [--keep]
#
# Requires: `claude` on PATH. Costs tokens and takes several minutes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/ship"

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

command -v claude >/dev/null || { echo "✗ claude CLI not found on PATH"; exit 1; }

( cd "$PLUGIN" && npm run build >/dev/null 2>&1 ) || { echo "✗ plugin build failed"; exit 1; }

TMP="$(mktemp -d)"
cleanup() { [ "$KEEP" -eq 1 ] && echo "kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

echo "Ship AUDIT E2E smoke"
echo "  workdir: $TMP"
echo "  plugin:  $PLUGIN"
echo

cd "$TMP"
git init -q
git config user.email e2e@ship.test
git config user.name "Ship E2E"

cat > package.json <<'JSON'
{ "name": "ship-audit-e2e", "version": "0.0.0", "type": "module",
  "scripts": { "test": "node --test" },
  "dependencies": { "express": "^4.18.0", "pg": "^8.11.0" } }
JSON
printf '.context/\nnode_modules/\n' > .gitignore

# --- Fixture: a small backend with planted, findable defects ------------------
mkdir -p src/routes src/services src/models config test lib

# Entrypoints — SQL injection by string concatenation (security: A03).
cat > src/routes/users.route.js <<'EOF'
import { Router } from 'express'
import { findUser, listOrdersForUsers } from '../services/user.service.js'

export const router = Router()

router.get('/users/:id', async (req, res) => {
  const user = await findUser(req.params.id)
  res.json(user)
})

router.get('/users/:id/orders', async (req, res) => {
  res.json(await listOrdersForUsers([req.params.id]))
})
EOF

# Services — N+1 query in a loop (backend performance).
cat > src/services/user.service.js <<'EOF'
import { pool } from '../models/db.js'

export async function findUser(id) {
  const result = await pool.query('SELECT * FROM users WHERE id = ' + id)
  return result.rows[0]
}

export async function listOrdersForUsers(ids) {
  const out = []
  for (const id of ids) {
    const r = await pool.query('SELECT * FROM orders WHERE user_id = $1', [id])
    out.push(...r.rows)
  }
  return out
}
EOF

# Data access — no index on a filtered column, SELECT * without LIMIT.
cat > src/models/db.js <<'EOF'
import pkg from 'pg'

export const pool = new pkg.Pool({ connectionString: process.env.DATABASE_URL })

export async function recentOrders() {
  const r = await pool.query('SELECT * FROM orders ORDER BY created_at DESC')
  return r.rows
}
EOF

cat > src/models/schema.sql <<'EOF'
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  email TEXT NOT NULL
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL,
  created_at TIMESTAMP DEFAULT now()
);
EOF

# Config — a hardcoded secret (security: A05/A02).
# Assembled here so this script carries no secret literal of its own — the
# generated fixture file does, which is what the security audit must find.
PLANTED_KEY="$(printf 'demo-%s-%s-%s' signing key notreal)"
cat > config/app.config.js <<EOF
export const config = {
  port: 3000,
  jwtSecret: '$PLANTED_KEY',
  dbUrl: process.env.DATABASE_URL
}
EOF

# --- The canary ---------------------------------------------------------------
# `lib/` matches no category heuristic and this file's name suggests nothing, so
# audit-inventory.sh files it under "Other source". It carries a command
# injection every security audit should find. If an audit only reads the
# categories the inventory highlights, this one goes unreported — which is the
# exact failure mode the inventory could introduce.
cat > lib/tooling.js <<'EOF'
import { execSync } from 'child_process'

export function convertAsset(userSuppliedName) {
  return execSync('convert ' + userSuppliedName + ' /tmp/out.png').toString()
}
EOF

# One real test so the coverage audit has something to correlate against.
cat > test/user.service.test.js <<'EOF'
import test from 'node:test'
import assert from 'node:assert'

test('placeholder', () => { assert.ok(true) })
EOF

mkdir -p ship
cat > ship/config.md <<'CFG'
# Ship Config

## Project
- Name: ship-audit-e2e
- Type: backend

## Linear Integration
- Configured: no

## Stack
- Language: JavaScript
- Runtime: Node.js
- Framework: Express
- Database: PostgreSQL
- Test Framework: node --test
- Package Manager: npm

## Security Focus
- categories: all

## Conventions
- Artifact language: en
- Prompt language: en
- Code language: English
CFG

git add -A
git commit -qm "baseline: audit fixture with planted defects"
git branch -M main
git update-ref refs/remotes/origin/main main

TO=""
if command -v timeout >/dev/null; then TO="timeout 2400"
elif command -v gtimeout >/dev/null; then TO="gtimeout 2400"; fi
run_claude() { $TO claude --print --dangerously-skip-permissions --plugin-dir "$PLUGIN" "$1"; }

echo "▶ /ship:audit:run ..."
run_claude "/ship:audit:run" || echo "  (audit:run returned non-zero — checking artifacts anyway)"

# --- Assertions ---------------------------------------------------------------
echo
fail=0
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✗\033[0m %s\n' "$1"; fail=1; }

INV=".context/ship-audit/inventory.md"
if [ -s "$INV" ]; then
  ok "inventory generated: $INV"
  # Generated once, not per audit.
  grep -q 'index, not a scope limit' "$INV" && ok "inventory carries the scope warning" \
    || bad "inventory is missing the index-not-a-scope-limit warning"
  cat_of() {
    awk -v p="- $1" '
      /^## / { cat = $0; sub(/^## /, "", cat); sub(/ \([0-9]+\)$/, "", cat) }
      $0 == p { print cat; exit }
    ' "$INV"
  }
  [ "$(cat_of src/routes/users.route.js)" = "Entrypoints" ] && ok "route classified as Entrypoints" \
    || bad "route classified as '$(cat_of src/routes/users.route.js)'"
  [ "$(cat_of src/services/user.service.js)" = "Services" ] && ok "service classified as Services" \
    || bad "service classified as '$(cat_of src/services/user.service.js)'"
  [ "$(cat_of src/models/db.js)" = "Data access" ] && ok "model classified as Data access" \
    || bad "model classified as '$(cat_of src/models/db.js)'"
  CANARY_CAT="$(cat_of lib/tooling.js)"
  [ "$CANARY_CAT" = "Other source" ] && ok "canary sits outside every highlighted category (Other source)" \
    || bad "canary landed in '$CANARY_CAT' — it must be unhighlighted for this test to mean anything"
else
  bad "no inventory produced — audit:run never ran audit-inventory.sh"
fi

REPORTS="$(ls ship/audits/*.md 2>/dev/null || true)"
if [ -n "$REPORTS" ]; then
  ok "audit reports: $(echo "$REPORTS" | tr '\n' ' ')"
else
  bad "no reports under ship/audits/"
fi

for kind in security tests backend; do
  ls ship/audits/${kind}-*.md >/dev/null 2>&1 && ok "report present: $kind" || bad "missing report: $kind"
done
ls ship/audits/run-*.md >/dev/null 2>&1 && ok "consolidated report present" || bad "no consolidated run-*.md"

# Planted defects the audits must surface. Grep by file path across every report:
# wording is model-dependent, the path is not.
found_in_reports() { grep -rqF "$1" ship/audits/ 2>/dev/null; }

found_in_reports 'src/services/user.service.js' && ok "SQL injection site reported (user.service.js)" \
  || bad "no report mentions src/services/user.service.js — the string-concatenated query was missed"
found_in_reports 'config/app.config.js' && ok "hardcoded secret site reported (app.config.js)" \
  || bad "no report mentions config/app.config.js — the hardcoded jwtSecret was missed"

# THE canary assertion.
if found_in_reports 'lib/tooling.js'; then
  ok "CANARY FOUND: the unhighlighted file was audited — the inventory is an index, not a scope limit"
else
  bad "CANARY MISSED: lib/tooling.js (command injection) appears in no report"
  echo "    The inventory filed it under '$CANARY_CAT'. If audits only read highlighted"
  echo "    categories, the index has become a denylist and coverage silently shrank."
fi

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mAUDIT E2E smoke: PASS\033[0m"; else echo -e "\033[31mAUDIT E2E smoke: FAIL\033[0m"; fi
exit "$fail"
