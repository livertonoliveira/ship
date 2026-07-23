'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const GATE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'findings-gate.sh');

function run(args) {
  return spawnSync('bash', [GATE, ...args], { cwd: process.cwd(), encoding: 'utf8' });
}

function parse(stdout) {
  const out = {};
  for (const line of stdout.split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  return out;
}

function scratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'findings-gate-'));
}

test('critical/high yields FAIL', () => {
  const res = run(['perf', '--critical', '0', '--high', '1', '--medium', '2', '--low', '3', '--config', '/nonexistent']);
  assert.equal(res.status, 0, res.stderr);
  const o = parse(res.stdout);
  assert.equal(o.gate, 'FAIL');
  assert.match(o.row, /^\| perf \| #<RUN> \|.*\| fail \| 0 \| 1 \| 2 \| 3 \|/);
});

test('only medium yields WARN', () => {
  const o = parse(run(['review', '--medium', '2', '--config', '/nonexistent']).stdout);
  assert.equal(o.gate, 'WARN');
});

test('only low or none yields PASS', () => {
  assert.equal(parse(run(['review', '--low', '5', '--config', '/nonexistent']).stdout).gate, 'PASS');
  assert.equal(parse(run(['review', '--config', '/nonexistent']).stdout).gate, 'PASS');
});

test('severity override high→warn downgrades FAIL to WARN and moves the count', () => {
  const dir = scratch();
  fs.writeFileSync(path.join(dir, 'config.md'), '# Config\n\n## Severity Overrides\n- perf: high→warn\n');
  const o = parse(run(['perf', '--high', '1', '--medium', '2', '--config', path.join(dir, 'config.md')]).stdout);
  assert.equal(o.gate, 'WARN');
  assert.equal(o.high, '0');
  assert.equal(o.medium, '3');
});

test('a config that exists but has no Severity Overrides section does not crash (bash 3.2 empty-array)', () => {
  const dir = scratch();
  fs.writeFileSync(path.join(dir, 'config.md'), '# Config\n\n## Gate Behavior\n- on_fail: ask\n');
  const res = run(['perf', '--high', '1', '--config', path.join(dir, 'config.md')]);
  assert.equal(res.status, 0, res.stderr);
  const o = parse(res.stdout);
  assert.equal(o.gate, 'FAIL');
  assert.equal(o.high, '1');
});

test('override for a different phase is ignored', () => {
  const dir = scratch();
  fs.writeFileSync(path.join(dir, 'config.md'), '# Config\n\n## Severity Overrides\n- security: high→warn\n');
  const o = parse(run(['perf', '--high', '1', '--config', path.join(dir, 'config.md')]).stdout);
  assert.equal(o.gate, 'FAIL');
  assert.equal(o.high, '1');
});

test('--findings counts severities from a single-line JSON array', () => {
  const dir = scratch();
  fs.writeFileSync(
    path.join(dir, 'f.json'),
    '[{"severity":"critical","t":"x"},{"severity":"high"},{"severity":"high"},{"severity":"low"}]'
  );
  const o = parse(run(['security', '--findings', path.join(dir, 'f.json'), '--config', '/nonexistent']).stdout);
  assert.equal(o.critical, '1');
  assert.equal(o.high, '2');
  assert.equal(o.low, '1');
  assert.equal(o.gate, 'FAIL');
});

test('--findings on empty array is PASS', () => {
  const dir = scratch();
  fs.writeFileSync(path.join(dir, 'f.json'), '[]');
  const o = parse(run(['perf', '--findings', path.join(dir, 'f.json'), '--config', '/nonexistent']).stdout);
  assert.equal(o.gate, 'PASS');
  assert.equal(o.critical, '0');
});

test('--scratch writes the row to phase-status-<phase>.md with the #<RUN> placeholder', () => {
  const dir = scratch();
  run(['review', '--critical', '0', '--high', '0', '--medium', '1', '--low', '0', '--files', '5', '--scratch', dir, '--config', '/nonexistent']);
  const row = fs.readFileSync(path.join(dir, 'phase-status-review.md'), 'utf8');
  assert.match(row, /^\| review \| #<RUN> \|.*\| 5 \| warn \| 0 \| 0 \| 1 \| 0 \|/);
});

test('unknown phase fails fast', () => {
  const res = run(['bogus', '--low', '1', '--config', '/nonexistent']);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /unknown phase/);
});

test('non-integer count fails fast', () => {
  const res = run(['perf', '--high', 'x', '--config', '/nonexistent']);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /non-negative integers/);
});

test('the emitted row survives status-consolidate #<RUN> substitution', () => {
  const dir = scratch();
  run(['perf', '--medium', '1', '--scratch', dir, '--config', '/nonexistent']);
  const consolidate = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'status-consolidate.sh');
  const res = spawnSync('bash', [consolidate, '2', path.join(dir, 'phase-status-perf.md')], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /^\| perf \| #2 \|.*\| warn \| 0 \| 0 \| 1 \| 0 \|/);
});
