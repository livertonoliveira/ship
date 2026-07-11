'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { exitCodeFor } = require('./outcomes');

test('caso malformado faz exitCodeFor retornar código diferente de zero', () => {
  const outcome = { case: 'caseBroken', malformed: true };

  assert.equal(exitCodeFor(outcome), 1);
});

test('verdict noop não afeta exitCodeFor quando não malformado', () => {
  const outcome = { case: 'caseOne', malformed: false, verdict: 'noop' };

  assert.equal(exitCodeFor(outcome), 0);
});

test('exitCodeFor aceita lista de outcomes e retorna zero quando nenhum é malformado', () => {
  const outcomes = [
    { case: 'caseOne', malformed: false },
    { case: 'caseTwo', malformed: false },
  ];

  assert.equal(exitCodeFor(outcomes), 0);
});

test('exitCodeFor aceita lista de outcomes e retorna não zero quando algum é malformado', () => {
  const outcomes = [
    { case: 'caseOne', malformed: false },
    { case: 'caseTwo', malformed: true },
  ];

  assert.equal(exitCodeFor(outcomes), 1);
});
