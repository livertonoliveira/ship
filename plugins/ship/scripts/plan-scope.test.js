'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PLAN_SCOPE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'plan-scope.sh');
const HEADER =
  '# Dispatch Log\n\n| Phase | Tool | Name | Model | Timestamp |\n|-------|------|------|-------|-----------|\n';

function scratch(dispatchRows = '') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'plan-scope-'));
  fs.writeFileSync(path.join(dir, 'dispatch-log.md'), HEADER + dispatchRows);
  return dir;
}

function run(dir) {
  return spawnSync('bash', [PLAN_SCOPE, dir], { encoding: 'utf8' });
}

function planRows(dir) {
  return fs
    .readFileSync(path.join(dir, 'dispatch-log.md'), 'utf8')
    .split('\n')
    .filter((l) => /^\| *plan /.test(l));
}

test('backfills a skipped plan row when the planner was never recorded', () => {
  const dir = scratch();
  const res = run(dir);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /plan=skipped \(backfilled\)/);
  const rows = planRows(dir);
  assert.equal(rows.length, 1);
  assert.match(rows[0], /^\| plan \| - \| skipped \| - \|/);
});

test('the backfilled row satisfies the e2e skip grep', () => {
  const dir = scratch();
  run(dir);
  const log = fs.readFileSync(path.join(dir, 'dispatch-log.md'), 'utf8');
  assert.match(log, /^\| *plan .*\| *skipped /m);
});

test('does not duplicate when the planner was already dispatched', () => {
  const dir = scratch('| plan | Skill | ship:plan | sonnet | 2026-01-01T00:00:00Z |\n');
  const res = run(dir);
  assert.match(res.stdout, /plan=already-recorded/);
  assert.equal(planRows(dir).length, 1);
});

test('does not duplicate when the skip was already logged', () => {
  const dir = scratch('| plan | - | skipped | - | 2026-01-01T00:00:00Z |\n');
  const res = run(dir);
  assert.match(res.stdout, /plan=already-recorded/);
  assert.equal(planRows(dir).length, 1);
});

test('a dispatched planner row is never masked as skipped (real planner failures stay visible)', () => {
  // planner ran but wrote no plan.md → row exists (dispatched, not skipped) → no backfill,
  // so the e2e "planner ran but wrote none" branch still fires.
  const dir = scratch('| plan | Skill | ship:plan | sonnet | 2026-01-01T00:00:00Z |\n');
  run(dir);
  const log = fs.readFileSync(path.join(dir, 'dispatch-log.md'), 'utf8');
  assert.doesNotMatch(log, /^\| *plan .*\| *skipped /m);
});

test('missing scratch arg fails fast', () => {
  const res = spawnSync('bash', [PLAN_SCOPE], { encoding: 'utf8' });
  assert.equal(res.status, 1);
  assert.match(res.stderr, /usage/);
});
