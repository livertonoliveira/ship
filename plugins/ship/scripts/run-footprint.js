#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const { countWords } = require('./build');
const { FOOTPRINT_BUDGETS } = require('./budgets');

const PLUGIN_ROOT = process.env.RUN_FOOTPRINT_PLUGIN_ROOT
  ? path.resolve(process.env.RUN_FOOTPRINT_PLUGIN_ROOT)
  : path.resolve(__dirname, '..');

// Groups that share an aggregate ceiling. Before this, only `run` had one — so
// spec/init/graph and the whole audit surface were bounded by nothing but the
// per-file ceiling, and raising that ceiling would have left them unguarded.
const FOOTPRINT_GROUPS = {
  run: [
    'skills/run/SKILL.md',
    'skills/plan/SKILL.md',
    'skills/develop/SKILL.md',
    'skills/test/SKILL.md',
    'skills/review/SKILL.md',
    'skills/homolog/SKILL.md',
    'agents/ship-perf.md',
    'agents/ship-security.md',
    'agents/ship-review.md',
    'agents/ship-test-unit.md',
  ],
  spec: [
    'skills/spec/SKILL.md',
    'skills/init/SKILL.md',
    'skills/graph/SKILL.md',
  ],
  audit: [
    'skills/audit:backend/SKILL.md',
    'skills/audit:database/SKILL.md',
    'skills/audit:frontend/SKILL.md',
    'skills/audit:run/SKILL.md',
    'skills/audit:security/SKILL.md',
    'skills/audit:tests/SKILL.md',
    'agents/ship-audit-backend.md',
    'agents/ship-audit-database.md',
    'agents/ship-audit-frontend.md',
    'agents/ship-audit-security.md',
    'agents/ship-audit-tests.md',
  ],
};

const RUN_FOOTPRINT_FILES = FOOTPRINT_GROUPS.run;
function computeFootprint(pluginRoot, files) {
  const entries = files.map((relPath) => {
    const absPath = path.join(pluginRoot, relPath);
    const content = fs.readFileSync(absPath, 'utf8');
    return { file: relPath, wordCount: countWords(content) };
  });
  const total = entries.reduce((sum, entry) => sum + entry.wordCount, 0);
  return { entries, total };
}

function main() {
  let failed = false;

  for (const [group, files] of Object.entries(FOOTPRINT_GROUPS)) {
    const budget = FOOTPRINT_BUDGETS[group];
    const { entries, total } = computeFootprint(PLUGIN_ROOT, files);

    console.log(`\n[${group}]`);
    for (const { file, wordCount } of entries) {
      console.log(`${wordCount}\t${file}`);
    }
    console.log(`Total: ${total} / ${budget}`);

    if (total > budget) {
      console.error(
        `Erro: pegada de '${group}' é ${total} palavras, excede o teto de ${budget} em ${total - budget} palavras`
      );
      failed = true;
    }
  }

  if (failed) process.exit(1);
}

if (require.main === module) {
  main();
}

module.exports = { computeFootprint, FOOTPRINT_GROUPS, RUN_FOOTPRINT_FILES };
