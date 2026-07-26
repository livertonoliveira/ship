'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { countWords, checkBudget, skillKeyFromRelPath } = require('./build');
const { WORD_BUDGETS, DEFAULT_BUDGET, FOOTPRINT_BUDGETS } = require('./budgets');

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

test('no skill gets a per-file exception — the 1500 ceiling applies to run and homolog too', () => {
  // The old 1200 orchestrator tier existed because 999 left run and homolog no
  // room. At 1500 it is not an exception to anything, so it is gone rather than
  // kept as dead policy.
  for (const key of ['run', 'homolog']) {
    assert.equal(checkBudget(key, DEFAULT_BUDGET - 1, WORD_BUDGETS), null);
    assert.deepEqual(checkBudget(key, DEFAULT_BUDGET + 1, WORD_BUDGETS), {
      skillKey: key,
      wordCount: DEFAULT_BUDGET + 1,
      limit: DEFAULT_BUDGET,
    });
  }
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

test('the ceiling is a flat 1500 with no per-skill exceptions', () => {
  assert.deepEqual(WORD_BUDGETS, {});
  assert.equal(DEFAULT_BUDGET, 1500);
});

test('every footprint group is capped below the sum of its files per-file ceilings', () => {
  // An aggregate at or above that sum constrains nothing. This is what the old
  // run budget of 25000 would have become the moment the per-file ceiling rose:
  // 10 files x 1500 = 15000, so 25000 could never trip.
  const groupSizes = { run: 10, spec: 3, audit: 11 };
  for (const [group, files] of Object.entries(groupSizes)) {
    const budget = FOOTPRINT_BUDGETS[group];
    assert.ok(budget, `missing aggregate budget for ${group}`);
    assert.ok(
      budget < files * DEFAULT_BUDGET,
      `${group} budget ${budget} is not below ${files} x ${DEFAULT_BUDGET} — it would never trip`
    );
  }
});

test('build completes without process.exit(1) when a compiled skill is under the ceiling', () => {
  assert.equal(checkBudget('spec', DEFAULT_BUDGET - 1, WORD_BUDGETS), null);
});

test('build would trigger checkBudget process.exit(1) when a compiled skill exceeds the ceiling', () => {
  const violation = checkBudget('spec', DEFAULT_BUDGET + 1, WORD_BUDGETS);
  assert.deepEqual(violation, {
    skillKey: 'spec',
    wordCount: DEFAULT_BUDGET + 1,
    limit: DEFAULT_BUDGET,
  });
});
