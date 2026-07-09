'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { aggregate, sampleVariance } = require('./aggregate');

function repsFor(arm, assertion, passes) {
  return passes.map((pass, index) => ({ arm, rep: index, assertion, pass }));
}

test('pass-rate e variância por braço e asserção', () => {
  const results = [
    ...repsFor('treatment', 'checkA', [true, true, true, false]),
    ...repsFor('control', 'checkA', [true, false, false, false]),
  ];

  const summary = aggregate(results, { minReps: 4 });

  assert.equal(summary.checkA.treatment.passRate, 0.75);
  assert.equal(summary.checkA.treatment.n, 4);
  assert.equal(summary.checkA.control.passRate, 0.25);
  assert.equal(summary.checkA.control.n, 4);
  assert.ok(summary.checkA.treatment.variance >= 0);
  assert.ok(summary.checkA.control.variance >= 0);
});

test('variância dos resultados 0/1: pass,pass,pass -> 0', () => {
  const variance = sampleVariance([1, 1, 1]);
  assert.equal(variance, 0);
});

test('variância dos resultados 0/1: pass,fail -> máxima', () => {
  const variance = sampleVariance([1, 0]);
  assert.equal(variance, 0.25);
});

test('delta é treatment menos control', () => {
  const results = [
    ...repsFor('treatment', 'checkB', [true, true, true, true]),
    ...repsFor('control', 'checkB', [true, false, false, false]),
  ];

  const summary = aggregate(results, { minReps: 4 });

  assert.equal(summary.checkB.delta, 0.75);
});

test('control falha e treatment passa além do threshold -> justified', () => {
  const results = [
    ...repsFor('treatment', 'checkC', [true, true, true, true]),
    ...repsFor('control', 'checkC', [true, false, false, false]),
  ];

  const summary = aggregate(results, { threshold: 0.2, minReps: 4 });

  assert.equal(summary.checkC.verdict, 'justified');
});

test('control aproximadamente igual a treatment -> noop', () => {
  const results = [
    ...repsFor('treatment', 'checkD', [true, true, true, true, true, true, true, true, true, false]),
    ...repsFor('control', 'checkD', [true, true, true, true, true, true, true, true, true, false]),
  ];

  const summary = aggregate(results, { threshold: 0.2, minReps: 3 });

  assert.equal(summary.checkD.verdict, 'noop');
});

test('reps abaixo do mínimo -> inconclusive', () => {
  const results = [
    ...repsFor('treatment', 'checkE', [true]),
    ...repsFor('control', 'checkE', [false]),
  ];

  const summary = aggregate(results, { minReps: 3 });

  assert.equal(summary.checkE.verdict, 'inconclusive');
});
