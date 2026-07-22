'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');

function setupScratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-timings-'));
}

function runPipeline(dir, args) {
  return spawnSync('bash', [PIPELINE, ...args], { cwd: dir, encoding: 'utf8' });
}

test('dispatch appends an epoch-keyed row to timings.tsv', () => {
  const scratch = setupScratch();
  fs.writeFileSync(path.join(scratch, 'dispatch-log.md'), '# Dispatch Log\n\n');
  const res = runPipeline(scratch, ['dispatch', scratch, 'dev', 'Skill', 'ship:develop', 'sonnet']);
  assert.equal(res.status, 0, res.stderr);
  const tsv = fs.readFileSync(path.join(scratch, 'timings.tsv'), 'utf8');
  assert.match(tsv, /^\d+\tdev\tSkill\tship:develop$/m);
});

test('report-timings pairs consecutive dispatches into per-phase deltas plus a total', () => {
  const scratch = setupScratch();
  // Synthetic epochs so deltas are deterministic: plan 40s, dev 300s, then the
  // final row (perf) runs until "now" — its exact duration is unbounded, so we
  // only assert the first two rows and that a TOTAL line is emitted.
  const base = 1_700_000_000;
  fs.writeFileSync(
    path.join(scratch, 'timings.tsv'),
    `${base}\tplan\tSkill\tship:plan\n` +
      `${base + 40}\tdev\tSkill\tship:develop\n` +
      `${base + 340}\tperf\tAgent\tship-perf\n`
  );
  const res = runPipeline(scratch, ['report-timings', scratch]);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /phase\s+tool\s+seconds/);
  assert.match(res.stdout, /^plan\s+Skill\s+40$/m);
  assert.match(res.stdout, /^dev\s+Skill\s+300$/m);
  assert.match(res.stdout, /^TOTAL\s+\d+$/m);
});

test('report-timings fails cleanly when timings.tsv is absent', () => {
  const scratch = setupScratch();
  const res = runPipeline(scratch, ['report-timings', scratch]);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /timings\.tsv not found/);
});
