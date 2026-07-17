'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HOOK = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'rerun-scope.sh');

function run(args) {
  const res = spawnSync('bash', [HOOK, ...args], { encoding: 'utf8' });
  assert.equal(res.status, 0, `hook failed: ${res.stderr}`);
  return JSON.parse(res.stdout);
}

function tmpFile(name, content) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rerun-scope-'));
  const p = path.join(dir, name);
  fs.writeFileSync(p, content);
  return p;
}

test('analyze re-runs by default when the fix touched files', () => {
  const changed = tmpFile('changed.txt', 'src/auth/login.ts\n');
  const out = run([changed]);
  assert.equal(out.phases.analyze.rerun, true);
  assert.equal(out.phases.security.rerun, true);
});

test('analyze is skipped when every previous finding is spec-side', () => {
  const changed = tmpFile('changed.txt', 'src/auth/login.ts\n');
  const findings = tmpFile(
    'drift-findings.json',
    JSON.stringify([
      { category: 'DUP', severity: 'low' },
      { category: 'TERM', severity: 'low' },
    ])
  );
  const out = run([changed, findings]);
  assert.equal(out.phases.analyze.rerun, false);
  assert.match(out.phases.analyze.reason, /spec-side/);
  assert.equal(out.phases.review.rerun, true);
});

test('analyze still re-runs when any finding is code-side', () => {
  const changed = tmpFile('changed.txt', 'src/auth/login.ts\n');
  const findings = tmpFile(
    'drift-findings.json',
    JSON.stringify([
      { category: 'DUP', severity: 'low' },
      { category: 'IMPL', severity: 'critical' },
    ])
  );
  const out = run([changed, findings]);
  assert.equal(out.phases.analyze.rerun, true);
});

test('analyze re-runs when the findings file is missing or empty', () => {
  const changed = tmpFile('changed.txt', 'src/auth/login.ts\n');
  const missing = run([changed, path.join(os.tmpdir(), 'nope-does-not-exist.json')]);
  assert.equal(missing.phases.analyze.rerun, true);
  const empty = run([changed, tmpFile('drift-findings.json', '[]')]);
  assert.equal(empty.phases.analyze.rerun, true);
});
