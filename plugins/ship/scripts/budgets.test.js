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

test('checkBudget returns a violation when a known skillKey exceeds its tier limit', () => {
  const violation = checkBudget('run', 99999, WORD_BUDGETS);
  assert.deepEqual(violation, { skillKey: 'run', wordCount: 99999, limit: WORD_BUDGETS.run });
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
