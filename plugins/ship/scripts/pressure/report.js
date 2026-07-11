'use strict';

const MARKDOWN_HEADER = '| caso | asserção | treat passRate | treat var | ctrl passRate | ctrl var | delta | verdict |';
const MARKDOWN_SEPARATOR = '| --- | --- | --- | --- | --- | --- | --- | --- |';
const DECIMAL_PLACES = 2;

function toRows(byCase) {
  const rows = [];
  for (const caseName of Object.keys(byCase).sort()) {
    const aggregateResult = byCase[caseName];
    for (const assertionName of Object.keys(aggregateResult).sort()) {
      const entry = aggregateResult[assertionName];
      rows.push({
        case: caseName,
        assertion: assertionName,
        treatmentPassRate: entry.treatment.passRate,
        treatmentVariance: entry.treatment.variance,
        controlPassRate: entry.control.passRate,
        controlVariance: entry.control.variance,
        delta: entry.delta,
        verdict: entry.verdict,
      });
    }
  }
  return rows;
}

function formatNumber(value) {
  return value.toFixed(DECIMAL_PLACES);
}

function renderMarkdown(byCase) {
  const rows = toRows(byCase);
  const lines = [MARKDOWN_HEADER, MARKDOWN_SEPARATOR];
  for (const row of rows) {
    lines.push(
      `| ${row.case} | ${row.assertion} | ${formatNumber(row.treatmentPassRate)} | ${formatNumber(row.treatmentVariance)} | ${formatNumber(row.controlPassRate)} | ${formatNumber(row.controlVariance)} | ${formatNumber(row.delta)} | ${row.verdict} |`
    );
  }
  return lines.join('\n');
}

function renderJson(byCase) {
  return toRows(byCase);
}

module.exports = { renderMarkdown, renderJson };
