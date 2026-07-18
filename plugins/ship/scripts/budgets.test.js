'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { countWords, checkBudget, skillKeyFromRelPath } = require('./build');
const { WORD_BUDGETS, DEFAULT_BUDGET } = require('./budgets');

test('countWords is deterministic for the same input', () => {
  const content = 'the quick brown fox jumps over the lazy dog';
  assert.equal(countWords(content), countWords(content));
});

test('countWords counts concrete word totals', () => {
  assert.equal(countWords('one two three'), 3);
  assert.equal(countWords('   leading and trailing   spaces   '), 4);
  assert.equal(countWords(''), 0);
});

test('checkBudget returns a violation using DEFAULT_BUDGET when a skillKey has no explicit tier entry', () => {
  const violation = checkBudget('spec', 99999, WORD_BUDGETS);
  assert.deepEqual(violation, { skillKey: 'spec', wordCount: 99999, limit: DEFAULT_BUDGET });
});

test('checkBudget uses the orchestrator-tier limit for run/homolog', () => {
  const violation = checkBudget('run', 99999, WORD_BUDGETS);
  assert.deepEqual(violation, { skillKey: 'run', wordCount: 99999, limit: WORD_BUDGETS.run });
  assert.equal(WORD_BUDGETS.run, 1200);
  assert.equal(WORD_BUDGETS.homolog, 1200);
  assert.equal(checkBudget('run', 1100, WORD_BUDGETS), null);
});

test('checkBudget returns null when an unknown skillKey stays within DEFAULT_BUDGET', () => {
  const result = checkBudget('skill-inexistente', 1, WORD_BUDGETS);
  assert.equal(result, null);
});

test('checkBudget returns a DEFAULT_BUDGET violation when an unknown skillKey exceeds it', () => {
  const violation = checkBudget('skill-inexistente', DEFAULT_BUDGET + 1, WORD_BUDGETS);
  assert.deepEqual(violation, {
    skillKey: 'skill-inexistente',
    wordCount: DEFAULT_BUDGET + 1,
    limit: DEFAULT_BUDGET,
  });
});

test('skillKeyFromRelPath maps a nested SKILL.md path to its skill key', () => {
  assert.equal(skillKeyFromRelPath(path.join('audit', 'run', 'SKILL.md')), 'audit/run');
});

test('WORD_BUDGETS only exempts the orchestrator tier (run, homolog) — every other skillKey falls back to DEFAULT_BUDGET', () => {
  assert.deepEqual(WORD_BUDGETS, { run: 1200, homolog: 1200 });
  assert.equal(DEFAULT_BUDGET, 999);
});

test('build completes without process.exit(1) when the compiled spec skill is under the flat 999 ceiling', () => {
  const result = checkBudget('spec', 955, WORD_BUDGETS);
  assert.equal(result, null);
});

test('build would trigger checkBudget process.exit(1) when the compiled spec skill exceeds the flat 999 ceiling', () => {
  const violation = checkBudget('spec', 1000, WORD_BUDGETS);
  assert.deepEqual(violation, { skillKey: 'spec', wordCount: 1000, limit: DEFAULT_BUDGET });
});
