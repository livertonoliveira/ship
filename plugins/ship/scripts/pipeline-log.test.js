'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');

function sh(cwd, cmd, args) {
  return spawnSync(cmd, args, { cwd, encoding: 'utf8' });
}

function setupScratch() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-log-'));
  return dir;
}

function runPipeline(dir, args) {
  return sh(dir, 'bash', [PIPELINE, ...args]);
}

test('dispatch appends a table row and prints the summary line', () => {
  const scratch = setupScratch();
  fs.writeFileSync(path.join(scratch, 'dispatch-log.md'), '# Dispatch Log\n\n');
  const res = runPipeline(scratch, ['dispatch', scratch, 'dev', 'Skill', 'ship:develop', 'sonnet']);
  assert.equal(res.status, 0, res.stderr);
  const log = fs.readFileSync(path.join(scratch, 'dispatch-log.md'), 'utf8');
  assert.match(
    log,
    /\| dev \| Skill \| ship:develop \| sonnet \| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \|/
  );
  assert.match(res.stdout, /^▶ Fase: dev \| tool=Skill \| name=ship:develop \| model=sonnet/m);
});

test('dispatch rejects an unknown phase without mutating the log', () => {
  const scratch = setupScratch();
  const initial = '# Dispatch Log\n\n';
  fs.writeFileSync(path.join(scratch, 'dispatch-log.md'), initial);
  const res = runPipeline(scratch, ['dispatch', scratch, 'bogus-phase', 'Skill', 'ship:develop', 'sonnet']);
  assert.notEqual(res.status, 0);
  const log = fs.readFileSync(path.join(scratch, 'dispatch-log.md'), 'utf8');
  assert.equal(log, initial);
});

test('dispatch accepts the skip case and exits 0', () => {
  const scratch = setupScratch();
  fs.writeFileSync(path.join(scratch, 'dispatch-log.md'), '# Dispatch Log\n\n');
  const res = runPipeline(scratch, ['dispatch', scratch, 'test', '-', 'skipped', '-']);
  assert.equal(res.status, 0, res.stderr);
  const log = fs.readFileSync(path.join(scratch, 'dispatch-log.md'), 'utf8');
  assert.match(log, /\| test \| - \| skipped \| - \| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \|/);
  assert.match(res.stdout, /^▶ Fase: test \| tool=- \| name=skipped \| model=-/m);
});

test('complete consolidates rows across phases substituting the run number', () => {
  const scratch = setupScratch();
  fs.writeFileSync(
    path.join(scratch, 'phase-status-perf.md'),
    '| perf | #<RUN> | 2026-07-17T10:00:00Z | 3 | pass | 0 | 0 | 0 | 0 | |\n'
  );
  fs.writeFileSync(
    path.join(scratch, 'phase-status-review.md'),
    '| review | #<RUN> | 2026-07-17T10:05:00Z | 2 | pass | 0 | 0 | 0 | 0 | |\n'
  );
  fs.writeFileSync(path.join(scratch, 'phase-status.md'), '# Phase Status\n\n');
  const res = runPipeline(scratch, ['complete', scratch, '2', 'perf', 'review']);
  assert.equal(res.status, 0, res.stderr);
  const status = fs.readFileSync(path.join(scratch, 'phase-status.md'), 'utf8');
  assert.match(status, /\| perf \| #2 \|/);
  assert.match(status, /\| review \| #2 \|/);
});

test('complete rejects zero phases with a clean error and leaves phase-status.md untouched', () => {
  const scratch = setupScratch();
  const initial = '# Phase Status\n\n';
  fs.writeFileSync(path.join(scratch, 'phase-status.md'), initial);
  const res = runPipeline(scratch, ['complete', scratch, '1']);
  assert.notEqual(res.status, 0);
  assert.doesNotMatch(res.stderr, /unbound variable/);
  assert.match(res.stderr, /usage: pipeline\.sh/);
  const status = fs.readFileSync(path.join(scratch, 'phase-status.md'), 'utf8');
  assert.equal(status, initial);
});

test('complete fails and leaves phase-status.md untouched when a source file is missing', () => {
  const scratch = setupScratch();
  const initial = '# Phase Status\n\n| plan | #1 | 2026-07-17T09:00:00Z | 1 | pass | 0 | 0 | 0 | 0 | |\n';
  fs.writeFileSync(path.join(scratch, 'phase-status.md'), initial);
  const res = runPipeline(scratch, ['complete', scratch, '1', 'security']);
  assert.notEqual(res.status, 0);
  const status = fs.readFileSync(path.join(scratch, 'phase-status.md'), 'utf8');
  assert.equal(status, initial);
});
