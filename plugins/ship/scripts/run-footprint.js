#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const { countWords } = require('./build');
const { RUN_FOOTPRINT_BUDGET } = require('./budgets');

const PLUGIN_ROOT = process.env.RUN_FOOTPRINT_PLUGIN_ROOT
  ? path.resolve(process.env.RUN_FOOTPRINT_PLUGIN_ROOT)
  : path.resolve(__dirname, '..');

const RUN_FOOTPRINT_FILES = [
  'skills/run/SKILL.md',
  'skills/plan/SKILL.md',
  'skills/develop/SKILL.md',
  'skills/test/SKILL.md',
  'skills/review/SKILL.md',
  'skills/analyze/SKILL.md',
  'skills/homolog/SKILL.md',
  'agents/ship-perf.md',
  'agents/ship-security.md',
  'agents/ship-review.md',
  'agents/ship-analyze.md',
  'agents/ship-test-unit.md',
];

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
  const { entries, total } = computeFootprint(PLUGIN_ROOT, RUN_FOOTPRINT_FILES);

  for (const { file, wordCount } of entries) {
    console.log(`${wordCount}\t${file}`);
  }
  console.log(`\nTotal: ${total} / ${RUN_FOOTPRINT_BUDGET}`);

  if (total > RUN_FOOTPRINT_BUDGET) {
    const overage = total - RUN_FOOTPRINT_BUDGET;
    console.error(
      `Erro: pegada do run típico é ${total} palavras, excede o teto de ${RUN_FOOTPRINT_BUDGET} em ${overage} palavras`
    );
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = { computeFootprint, RUN_FOOTPRINT_FILES };
