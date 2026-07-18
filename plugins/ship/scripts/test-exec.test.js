'use strict';

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

function setupProject({ testRunner, packageManager, testFileContent } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'test-exec-'));
  fs.mkdirSync(path.join(dir, 'scratch'));
  fs.mkdirSync(path.join(dir, 'tests'));
  fs.mkdirSync(path.join(dir, 'ship'));

  const stackLines = ['# Stack', ''];
  if (testRunner !== undefined) stackLines.push(`- Test runner: ${testRunner}`);
  if (packageManager !== undefined) stackLines.push(`- Package manager: ${packageManager}`);
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), stackLines.join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'ship', 'config.md'), '# Config\n');

  if (testFileContent !== undefined) {
    fs.writeFileSync(path.join(dir, 'tests', 'math.test.js'), testFileContent);
  }
  return dir;
}

const PASSING_TEST = `
const { test } = require('node:test');
const assert = require('node:assert');
test('adds numbers', () => { assert.ok(true); });
`;

const FAILING_TEST = `
const { test } = require('node:test');
const assert = require('node:assert');
test('adds numbers', () => { assert.ok(false); });
test('subtracts numbers', () => { assert.ok(false); });
`;

test('green suite writes header-only test-failures.md and exits 0', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.equal(failuresContent.trim(), '# Test Failures');
  const statusRow = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-test.md'), 'utf8');
  assert.match(statusRow, /\| test \| #<RUN> \|.*\| pass \|/);
});

test('red suite lists the failing file with its failure count and exits 1', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: FAILING_TEST,
  });
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /tests\/math\.test\.js \(2 failures\)/);
  const statusRow = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-test.md'), 'utf8');
  assert.match(statusRow, /\| test \| #<RUN> \|.*\| fail \|/);
});

test('missing test command exits 2 with the consulted config path in stderr', () => {
  const dir = setupProject({ testRunner: 'unknown', packageManager: 'unknown' });
  const res = run(dir, ['scratch', '--config', 'ship/config.md']);
  assert.equal(res.status, 2);
  assert.match(res.stderr, /test command not found/);
  assert.match(res.stderr, /ship\/config\.md/);
});

test('missing stack.md falls back to ship/config.md and still exits 2 when unresolved', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'test-exec-'));
  fs.mkdirSync(path.join(dir, 'scratch'));
  fs.mkdirSync(path.join(dir, 'ship'));
  fs.writeFileSync(path.join(dir, 'ship', 'config.md'), '# Config\n');
  const res = run(dir, ['scratch', '--config', 'ship/config.md']);
  assert.equal(res.status, 2);
  assert.match(res.stderr, /test command not found: ship\/config\.md/);
});

test('resolves the test command from ship/config.md when stack.md has none', () => {
  const dir = setupProject({ testFileContent: PASSING_TEST });
  fs.writeFileSync(
    path.join(dir, 'ship', 'config.md'),
    '# Config\n\n- Test runner: node --test\n- Package manager: npm\n'
  );
  const res = run(dir, ['scratch', '--config', 'ship/config.md']);
  assert.equal(res.status, 0, res.stderr);
});

test('restricts execution to files listed in generated-tests.md', () => {
  const dir = setupProject({ testRunner: 'node --test', packageManager: 'npm' });
  fs.writeFileSync(path.join(dir, 'tests', 'a.test.js'), PASSING_TEST);
  fs.writeFileSync(path.join(dir, 'tests', 'b.test.js'), FAILING_TEST);
  fs.writeFileSync(
    path.join(dir, 'scratch', 'generated-tests.md'),
    '# Generated Tests\n\n- tests/a.test.js (unit)\n'
  );
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.equal(failuresContent.trim(), '# Test Failures');
});

test('jest-style runner composes "<package manager> test", forwards file args after --, and parses FAIL blocks', () => {
  const dir = setupProject({ testRunner: 'jest', packageManager: 'npm' });
  const fakeJest = path.join(dir, 'fake-jest.sh');
  fs.writeFileSync(
    fakeJest,
    [
      '#!/usr/bin/env bash',
      'echo "PASS src/foo.test.js"',
      'echo "FAIL src/bar.test.js"',
      'echo "  ✕ does a thing"',
      'echo "  ✕ does another thing"',
      'exit 1',
      '',
    ].join('\n')
  );
  fs.chmodSync(fakeJest, 0o755);
  fs.writeFileSync(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 'fixture', scripts: { test: './fake-jest.sh' } })
  );
  fs.writeFileSync(
    path.join(dir, 'scratch', 'generated-tests.md'),
    '# Generated Tests\n\n- src/bar.test.js (unit)\n'
  );
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /src\/bar\.test\.js \(2 failures\)/);
});

test('pytest-style FAILED summary lines are parsed into per-file failure counts', () => {
  const dir = setupProject({ testRunner: undefined, packageManager: undefined });
  const fakePytest = path.join(dir, 'fake-pytest.sh');
  fs.writeFileSync(
    fakePytest,
    [
      '#!/usr/bin/env bash',
      'echo "===== FAILURES ====="',
      'echo "FAILED test_math.py::test_addition - AssertionError"',
      'echo "FAILED test_math.py::test_subtraction - AssertionError"',
      'exit 1',
      '',
    ].join('\n')
  );
  fs.chmodSync(fakePytest, 0o755);
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), `# Stack\n\n- Test runner: ${fakePytest}\n`);
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /test_math\.py \(2 failures\)/);
});
