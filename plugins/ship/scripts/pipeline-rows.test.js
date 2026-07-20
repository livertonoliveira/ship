'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');

const HEADER =
  '# Phase Status\n\n| Phase | Run | Timestamp | Files | Gate | Critical | High | Medium | Low | Notes |\n' +
  '|-------|-----|-----------|-------|------|----------|------|--------|-----|-------|\n';

function withStatus(rows) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-rows-'));
  fs.writeFileSync(path.join(dir, 'phase-status.md'), HEADER + rows.join('\n') + '\n');
  return dir;
}

function rows(dir) {
  return spawnSync('bash', [PIPELINE, 'rows', dir], { encoding: 'utf8' });
}

test('emits the last full row per phase in first-seen order', () => {
  const dir = withStatus([
    '| dev | #1 | 2026-05-01T10:00:00Z | - | pass | 0 | 0 | 0 | 0 | |',
    '| perf | #1 | 2026-05-01T10:02:00Z | src/a.ts | warn | 0 | 0 | 2 | 1 | N+1 |',
    '| perf | #2 | 2026-05-01T10:05:00Z | src/a.ts | pass | 0 | 0 | 0 | 0 | re-run |',
    '| security | #1 | 2026-05-01T10:02:00Z | - | pass | 0 | 0 | 0 | 0 | |',
  ]);
  const out = rows(dir).stdout.trim().split('\n');
  assert.equal(out.length, 3);
  assert.match(out[0], /^\| dev \|/);
  assert.match(out[1], /^\| perf \| #2 \|.*\| pass \|/);
  assert.match(out[2], /^\| security \|/);
});

test('ignores the header and separator rows', () => {
  const dir = withStatus(['| dev | #1 | 2026-05-01T10:00:00Z | - | pass | 0 | 0 | 0 | 0 | |']);
  const out = rows(dir).stdout.trim().split('\n');
  assert.equal(out.length, 1);
  assert.match(out[0], /^\| dev \|/);
});

test('missing phase-status.md fails fast', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-rows-'));
  const res = rows(dir);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /phase-status\.md not found/);
});
