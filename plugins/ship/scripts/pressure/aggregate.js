'use strict';

const DEFAULT_THRESHOLD = 0.2;
const DEFAULT_MIN_REPS = 3;

function sampleVariance(values) {
  const n = values.length;
  if (n === 0) {
    return 0;
  }
  const mean = values.reduce((sum, value) => sum + value, 0) / n;
  const sumSquaredDiff = values.reduce((sum, value) => sum + (value - mean) ** 2, 0);
  return sumSquaredDiff / n;
}

function summarizeArm(results) {
  const values = results.map((result) => (result.pass ? 1 : 0));
  const n = values.length;
  const passes = values.reduce((sum, value) => sum + value, 0);
  return {
    passRate: n === 0 ? 0 : passes / n,
    variance: sampleVariance(values),
    n,
  };
}

function computeVerdict(treatment, control, threshold, minReps) {
  if (Math.min(treatment.n, control.n) < minReps) {
    return 'inconclusive';
  }
  const delta = treatment.passRate - control.passRate;
  return delta >= threshold ? 'justified' : 'noop';
}

function aggregate(results, options) {
  const threshold = options?.threshold ?? DEFAULT_THRESHOLD;
  const minReps = options?.minReps ?? DEFAULT_MIN_REPS;

  const byAssertion = new Map();
  for (const result of results) {
    if (!byAssertion.has(result.assertion)) {
      byAssertion.set(result.assertion, { treatment: [], control: [] });
    }
    const bucket = byAssertion.get(result.assertion);
    if (result.arm === 'treatment') {
      bucket.treatment.push(result);
    } else if (result.arm === 'control') {
      bucket.control.push(result);
    }
  }

  const summary = {};
  for (const [assertion, bucket] of byAssertion) {
    const treatment = summarizeArm(bucket.treatment);
    const control = summarizeArm(bucket.control);
    const delta = treatment.passRate - control.passRate;
    summary[assertion] = {
      treatment,
      control,
      delta,
      verdict: computeVerdict(treatment, control, threshold, minReps),
    };
  }

  return summary;
}

module.exports = { aggregate, sampleVariance };
