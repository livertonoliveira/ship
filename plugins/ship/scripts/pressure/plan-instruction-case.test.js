'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadCase, listReps, repArtifacts } = require('./cases');
const { runAssertion } = require('./assert');
const { aggregate } = require('./aggregate');
const { renderMarkdown } = require('./report');

const CASE_NAME = 'plan-instruction';
const CASE_DIR = path.join(__dirname, '..', '..', '..', '..', 'pressure', 'cases', CASE_NAME);

function renderCaseReport(caseDir, caseName) {
  const meta = loadCase(caseDir);
  const results = [];

  for (const arm of ['treatment', 'control']) {
    const reps = listReps(caseDir, arm);
    for (const repPath of reps) {
      const repId = path.basename(repPath);
      const artifacts = repArtifacts(caseDir, arm, repId);
      for (const assertionName of meta.assertions) {
        const result = runAssertion(assertionName, artifacts, meta);
        result.arm = arm;
        results.push(result);
      }
    }
  }

  const byCase = { [caseName]: aggregate(results) };
  return renderMarkdown(byCase);
}

test('replay do caso plan-instruction produz relatórios idênticos em execuções repetidas', () => {
  const firstReport = renderCaseReport(CASE_DIR, CASE_NAME);
  const secondReport = renderCaseReport(CASE_DIR, CASE_NAME);

  assert.equal(firstReport, secondReport);
  assert.match(firstReport, new RegExp(CASE_NAME));
  assert.match(firstReport, /planSchema/);
});
