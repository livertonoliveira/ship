'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { renderMarkdown, renderJson } = require('./report');

function sampleAggregate() {
  return {
    checkA: {
      treatment: { passRate: 0.75, variance: 0.1875, n: 4 },
      control: { passRate: 0.25, variance: 0.1875, n: 4 },
      delta: 0.5,
      verdict: 'justified',
    },
    checkB: {
      treatment: { passRate: 0.5, variance: 0.25, n: 4 },
      control: { passRate: 0.5, variance: 0.25, n: 4 },
      delta: 0,
      verdict: 'noop',
    },
  };
}

test('renderMarkdown gera uma linha por asserção com passRate, variância, delta e verdict', () => {
  const byCase = { caseOne: sampleAggregate() };

  const markdown = renderMarkdown(byCase);
  const lines = markdown.split('\n');

  assert.equal(lines.length, 4);
  assert.match(lines[0], /caso.*asserção.*treat passRate.*treat var.*ctrl passRate.*ctrl var.*delta.*verdict/);
  assert.match(lines[2], /caseOne \| checkA \| 0\.75 \| 0\.19 \| 0\.25 \| 0\.19 \| 0\.50 \| justified/);
  assert.match(lines[3], /caseOne \| checkB \| 0\.50 \| 0\.25 \| 0\.50 \| 0\.25 \| 0\.00 \| noop/);
});

test('renderJson contém os mesmos campos por asserção', () => {
  const byCase = { caseOne: sampleAggregate() };

  const rows = renderJson(byCase);

  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0], {
    case: 'caseOne',
    assertion: 'checkA',
    treatmentPassRate: 0.75,
    treatmentVariance: 0.1875,
    controlPassRate: 0.25,
    controlVariance: 0.1875,
    delta: 0.5,
    verdict: 'justified',
  });
  assert.deepEqual(rows[1], {
    case: 'caseOne',
    assertion: 'checkB',
    treatmentPassRate: 0.5,
    treatmentVariance: 0.25,
    controlPassRate: 0.5,
    controlVariance: 0.25,
    delta: 0,
    verdict: 'noop',
  });
});

test('verdict noop é finding e não falha a suite', () => {
  const byCase = { caseOne: sampleAggregate() };
  const rows = renderJson(byCase);
  assert.ok(rows.some((row) => row.verdict === 'noop'));
});
