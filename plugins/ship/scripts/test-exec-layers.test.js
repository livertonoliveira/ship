'use strict';

// A generated test only produces coverage if the command that runs it can see
// it. The manifest always carried the layer — `- <path> (<layer>)` — and
// test-exec parsed it off and threw it away, running everything through the one
// generic `test` script. On a project whose e2e files live behind a separate
// runner config, the contract's own test was never loaded and the phase
// reported green.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HOOK = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'test-exec.sh');

function run(cwd, args) {
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  return spawnSync('bash', [HOOK, ...args], { cwd, encoding: 'utf8', env });
}

// Each script appends its own name plus the file arguments it received, so the
// assertions can prove which runner saw which file.
function setupProject({ scripts, manifest }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'test-exec-layers-'));
  fs.mkdirSync(path.join(dir, 'scratch'));
  fs.mkdirSync(path.join(dir, 'ship'));
  fs.mkdirSync(path.join(dir, 'test'), { recursive: true });

  fs.writeFileSync(
    path.join(dir, 'scratch', 'stack.md'),
    '# Stack\n\n- Test Framework: jest\n- Package Manager: npm\n'
  );
  fs.writeFileSync(path.join(dir, 'ship', 'config.md'), '# Config\n');
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: 'p', scripts }, null, 2));
  fs.writeFileSync(path.join(dir, 'scratch', 'generated-tests.md'), manifest);
  return dir;
}

function invocations(dir) {
  const f = path.join(dir, 'invocations.txt');
  return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean) : [];
}

const RECORD = (name) => `node -e "require('fs').appendFileSync('invocations.txt','${name} '+process.argv.slice(1).join(' ')+'\\n')"`;

test('an e2e file is run by test:e2e, not by the generic test script', () => {
  const dir = setupProject({
    scripts: { test: RECORD('generic'), 'test:e2e': RECORD('e2e') },
    manifest: '# Generated Tests\n\n- test/checkout.e2e-spec.ts (e2e)\n',
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const calls = invocations(dir);
  assert.equal(calls.length, 1, `expected one runner invocation, got ${JSON.stringify(calls)}`);
  assert.match(calls[0], /^e2e /);
  assert.match(calls[0], /test\/checkout\.e2e-spec\.ts/);
});

test('layers are dispatched to their own scripts in the same run', () => {
  const dir = setupProject({
    scripts: {
      test: RECORD('generic'),
      'test:unit': RECORD('unit'),
      'test:e2e': RECORD('e2e'),
    },
    manifest: '# Generated Tests\n\n- test/a.spec.ts (unit)\n- test/b.e2e-spec.ts (e2e)\n',
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const calls = invocations(dir);
  assert.equal(calls.length, 2);
  const unit = calls.find((c) => c.startsWith('unit '));
  const e2e = calls.find((c) => c.startsWith('e2e '));
  assert.ok(unit && /test\/a\.spec\.ts/.test(unit), `unit call: ${unit}`);
  assert.ok(e2e && /test\/b\.e2e-spec\.ts/.test(e2e), `e2e call: ${e2e}`);
  // No cross-contamination: neither runner receives the other layer's file.
  assert.ok(!/b\.e2e-spec/.test(unit));
  assert.ok(!/a\.spec\.ts/.test(e2e));
});

test('a layer with no dedicated script falls back to the generic one', () => {
  const dir = setupProject({
    scripts: { test: RECORD('generic') },
    manifest: '# Generated Tests\n\n- test/a.spec.ts (integration)\n',
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const calls = invocations(dir);
  assert.equal(calls.length, 1);
  assert.match(calls[0], /^generic /);
  assert.match(calls[0], /test\/a\.spec\.ts/);
});

test('a failing layer fails the phase even when another layer is green', () => {
  const dir = setupProject({
    scripts: {
      test: RECORD('generic'),
      'test:unit': RECORD('unit'),
      'test:e2e': 'node -e "process.exit(1)"',
    },
    manifest: '# Generated Tests\n\n- test/a.spec.ts (unit)\n- test/b.e2e-spec.ts (e2e)\n',
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1, 'a red layer must fail the phase');
  const statusRow = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-test.md'), 'utf8');
  assert.match(statusRow, /\| test \| #<RUN> \|.*\| fail \|/);
});

test('an empty manifest still runs the generic suite once', () => {
  const dir = setupProject({
    scripts: { test: RECORD('generic') },
    manifest: '# Generated Tests\n\n',
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const calls = invocations(dir);
  assert.equal(calls.length, 1);
  assert.match(calls[0], /^generic\s*$/);
});
