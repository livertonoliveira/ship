'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HOOK = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'analyze-precheck.sh');

const reqId = (n) => 'REQ' + '-0' + n;

function setup(spec, diff) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'analyze-precheck-'));
  fs.writeFileSync(path.join(dir, 'spec.md'), spec);
  fs.writeFileSync(path.join(dir, 'diff.md'), diff);
  fs.mkdirSync(path.join(dir, 'scratch'), { recursive: true });
  return dir;
}

function run(dir, extra = []) {
  return spawnSync(
    'bash',
    [
      HOOK,
      path.join(dir, 'spec.md'),
      path.join(dir, 'diff.md'),
      '--scratch',
      path.join(dir, 'scratch'),
      '--config',
      '/nonexistent',
      ...extra,
    ],
    { cwd: dir, encoding: 'utf8' }
  );
}

test('a fully clean correlation skips the Agent and writes a PASS row', () => {
  const dir = setup('# Notes\n\nJust prose, no requirements.\n', '');
  const res = run(dir);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /^agent=skip$/m);
  const row = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-analyze.md'), 'utf8');
  assert.match(row, /\| analyze \| #<RUN> \|.*\| pass \| 0 \| 0 \| 0 \| 0 \|/);
});

test('an unimplemented requirement defers to the Agent and writes no row', () => {
  const dir = setup('### ' + reqId(1) + ': billing invoice generation endpoint\n', '');
  const res = run(dir);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /^agent=run$/m);
  assert.equal(fs.existsSync(path.join(dir, 'scratch', 'phase-status-analyze.md')), false);
});

test('a correlation failure defers to the Agent rather than guessing', () => {
  const dir = setup('# Notes\n', '');
  const res = spawnSync(
    'bash',
    [HOOK, path.join(dir, 'spec.md'), path.join(dir, 'missing.md'), '--config', '/nonexistent'],
    { cwd: dir, encoding: 'utf8' }
  );
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /^agent=run$/m);
});
