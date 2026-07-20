'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SCOPE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'quality-scope.sh');
const ALL = 'perf security review analyze';

function run(cls, phases, scratch) {
  const args = [SCOPE, cls, '--phases', phases, '--config', '/nonexistent'];
  if (scratch) args.push('--scratch', scratch);
  return spawnSync('bash', args, { encoding: 'utf8' });
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
  return fs.mkdtempSync(path.join(os.tmpdir(), 'quality-scope-'));
}

test('normal runs all enabled quality phases and skips none', () => {
  const o = parse(run('normal', ALL).stdout);
  assert.equal(o.run, 'perf security review analyze');
  assert.equal(o.skip, '');
});

test('large runs all enabled quality phases and skips none', () => {
  const o = parse(run('large', ALL).stdout);
  assert.equal(o.run, 'perf security review analyze');
  assert.equal(o.skip, '');
});

test('minor runs security+analyze and skips perf+review', () => {
  const o = parse(run('minor', ALL).stdout);
  assert.equal(o.run, 'security analyze');
  assert.equal(o.skip, 'perf review');
});

test('trivial skips every enabled quality phase and runs none', () => {
  const o = parse(run('trivial', ALL).stdout);
  assert.equal(o.run, '');
  assert.equal(o.skip, 'perf security review analyze');
});

test('the enabled subset is respected (disabled phases never appear)', () => {
  const o = parse(run('minor', 'perf analyze').stdout);
  assert.equal(o.run, 'analyze');
  assert.equal(o.skip, 'perf');
});

test('empty phase set yields empty run/skip without error', () => {
  const res = run('normal', '');
  assert.equal(res.status, 0, res.stderr);
  const o = parse(res.stdout);
  assert.equal(o.run, '');
  assert.equal(o.skip, '');
});

test('skipped phases get a PASS phase-status row with a skip note', () => {
  const dir = scratch();
  run('trivial', ALL, dir);
  for (const p of ['perf', 'security', 'review', 'analyze']) {
    const row = fs.readFileSync(path.join(dir, `phase-status-${p}.md`), 'utf8');
    assert.match(row, new RegExp(`^\\| ${p} \\| #<RUN> \\|.*\\| pass \\| 0 \\| 0 \\| 0 \\| 0 \\| diff trivial — pulado \\|`));
  }
});

test('run phases do not get a skip row written', () => {
  const dir = scratch();
  run('minor', ALL, dir);
  assert.ok(fs.existsSync(path.join(dir, 'phase-status-perf.md')));
  assert.ok(fs.existsSync(path.join(dir, 'phase-status-review.md')));
  assert.ok(!fs.existsSync(path.join(dir, 'phase-status-security.md')));
  assert.ok(!fs.existsSync(path.join(dir, 'phase-status-analyze.md')));
});

test('unknown class fails fast', () => {
  const res = run('huge', ALL);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /unknown class/);
});

function writeConfig(dir, body) {
  const p = path.join(dir, 'config.md');
  fs.writeFileSync(p, body);
  return p;
}

test('a phase disabled via Pipeline Phases never runs, even if listed in --phases', () => {
  const dir = scratch();
  const config = writeConfig(dir, [
    '## Pipeline Profile',
    '- profile: standard',
    '',
    '## Pipeline Phases',
    '- perf: enabled',
    '- security: disabled',
    '- review: enabled',
  ].join('\n'));
  const res = spawnSync('bash', [SCOPE, 'normal', '--phases', ALL, '--config', config], { encoding: 'utf8' });
  const o = parse(res.stdout);
  assert.equal(o.run, 'perf review analyze');
  assert.equal(o.skip, '');
});

test('profile default governs a phase with no explicit Pipeline Phases override', () => {
  const dir = scratch();
  const config = writeConfig(dir, [
    '## Pipeline Profile',
    '- profile: standard',
  ].join('\n'));
  // standard profile: perf/security off by default, review on — see profiles.md
  const res = spawnSync('bash', [SCOPE, 'normal', '--phases', ALL, '--config', config], { encoding: 'utf8' });
  const o = parse(res.stdout);
  assert.equal(o.run, 'review analyze');
  assert.equal(o.skip, '');
});

test('strict profile enables perf/security by default', () => {
  const dir = scratch();
  const config = writeConfig(dir, [
    '## Pipeline Profile',
    '- profile: strict',
  ].join('\n'));
  const res = spawnSync('bash', [SCOPE, 'normal', '--phases', ALL, '--config', config], { encoding: 'utf8' });
  const o = parse(res.stdout);
  assert.equal(o.run, 'perf security review analyze');
  assert.equal(o.skip, '');
});

test('Security Focus categories: none forces security off, even when Pipeline Phases enables it', () => {
  const dir = scratch();
  const config = writeConfig(dir, [
    '## Pipeline Profile',
    '- profile: strict',
    '',
    '## Pipeline Phases',
    '- security: enabled',
    '',
    '## Security Focus',
    '- categories: none',
  ].join('\n'));
  const res = spawnSync('bash', [SCOPE, 'normal', '--phases', ALL, '--config', config], { encoding: 'utf8' });
  const o = parse(res.stdout);
  assert.equal(o.run, 'perf review analyze');
  assert.equal(o.skip, '');
});

test('Security Focus categories other than none do not affect security enablement', () => {
  const dir = scratch();
  const config = writeConfig(dir, [
    '## Pipeline Profile',
    '- profile: strict',
    '',
    '## Security Focus',
    '- categories: web-api',
  ].join('\n'));
  const res = spawnSync('bash', [SCOPE, 'normal', '--phases', ALL, '--config', config], { encoding: 'utf8' });
  const o = parse(res.stdout);
  assert.equal(o.run, 'perf security review analyze');
});

test('Pipeline Phases override wins over profile default', () => {
  const dir = scratch();
  const config = writeConfig(dir, [
    '## Pipeline Profile',
    '- profile: lite',
    '',
    '## Pipeline Phases',
    '- test: enabled',
    '- security: enabled',
  ].join('\n'));
  // lite profile: perf/security/review all off by default, but security is overridden on
  const res = spawnSync('bash', [SCOPE, 'normal', '--phases', ALL, '--config', config], { encoding: 'utf8' });
  const o = parse(res.stdout);
  assert.equal(o.run, 'security analyze');
  assert.equal(o.skip, '');
});
