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

test('security and review re-run by default when the fix touched files', () => {
  const changed = tmpFile('changed.txt', 'src/auth/login.ts\n');
  const out = run([changed]);
  assert.equal(out.phases.security.rerun, true);
  assert.equal(out.phases.review.rerun, true);
});

test('perf re-runs only when a changed file matches its src/**|lib/** scope', () => {
  const inScope = run([tmpFile('changed.txt', 'src/auth/login.ts\n')]);
  assert.equal(inScope.phases.perf.rerun, true);
  const outOfScope = run([tmpFile('changed.txt', 'docs/readme.md\n')]);
  assert.equal(outOfScope.phases.perf.rerun, false);
});

test('on_fail_rerun: all forces every phase to rerun, bypassing scope mapping', () => {
  // Without --config, a docs-only change wouldn't match perf's src/**|lib/** scope.
  const changed = tmpFile('changed.txt', 'docs/readme.md\n');
  const configDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rerun-scope-config-'));
  const config = path.join(configDir, 'config.md');
  fs.writeFileSync(config, '## Gate Behavior\n- on_fail_rerun: all\n');
  const out = run([changed, '--config', config]);
  assert.equal(out.phases.perf.rerun, true);
  assert.equal(out.phases.security.rerun, true);
  assert.equal(out.phases.review.rerun, true);
  assert.match(out.phases.perf.reason, /on_fail_rerun: all/);
});

test('on_fail_rerun: surgical (default) keeps scope mapping even with --config passed', () => {
  const changed = tmpFile('changed.txt', 'docs/readme.md\n');
  const configDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rerun-scope-config-'));
  const config = path.join(configDir, 'config.md');
  fs.writeFileSync(config, '## Gate Behavior\n- on_fail_rerun: surgical\n');
  const out = run([changed, '--config', config]);
  assert.equal(out.phases.perf.rerun, false);
  assert.equal(out.phases.security.rerun, true);
});

test('a missing --config falls back to surgical scope mapping (back-compat)', () => {
  const changed = tmpFile('changed.txt', 'docs/readme.md\n');
  const out = run([changed]);
  assert.equal(out.phases.perf.rerun, false);
});

test('on_fail_rerun: all does not override the empty-fix case', () => {
  const configDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rerun-scope-config-'));
  const config = path.join(configDir, 'config.md');
  fs.writeFileSync(config, '## Gate Behavior\n- on_fail_rerun: all\n');
  const empty = tmpFile('changed.txt', '');
  const out = run([empty, '--config', config]);
  assert.equal(out.phases.perf.rerun, false);
  assert.equal(out.phases.perf.reason, 'no changed files');
  assert.equal(out.empty, true);
});
