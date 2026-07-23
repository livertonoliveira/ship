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
  if (testRunner !== undefined) stackLines.push(`- Test Framework: ${testRunner}`);
  if (packageManager !== undefined) stackLines.push(`- Package Manager: ${packageManager}`);
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
    '# Config\n\n- Test Framework: node --test\n- Package Manager: npm\n'
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

test('jest "Test suite failed to run" (FAIL block, no ✕ markers) is listed as a failing file', () => {
  const dir = setupProject({ testRunner: 'jest', packageManager: 'npm' });
  const fakeJest = path.join(dir, 'fake-jest.sh');
  fs.writeFileSync(
    fakeJest,
    [
      '#!/usr/bin/env bash',
      'echo "FAIL src/broken.test.js"',
      "echo '  ● Test suite failed to run'",
      "echo '    Cannot find module \\'../missing\\' from \\'src/broken.test.js\\''",
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
    '# Generated Tests\n\n- src/broken.test.js (unit)\n'
  );
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /src\/broken\.test\.js \(1 failure\)/);
  assert.doesNotMatch(failuresContent, /\(unparsed\)/);
});

test('suite failing with unparseable output embeds the raw tail instead of a contentless marker', () => {
  const dir = setupProject({ testRunner: undefined, packageManager: undefined });
  const fakeRunner = path.join(dir, 'fake-runner.sh');
  fs.writeFileSync(
    fakeRunner,
    [
      '#!/usr/bin/env bash',
      "echo 'RuntimeError: database connection refused at bootstrap'",
      'exit 1',
      '',
    ].join('\n')
  );
  fs.chmodSync(fakeRunner, 0o755);
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), `# Stack\n\n- Test Framework: ${fakeRunner}\n`);
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /## Test suite failed \(could not parse failing files\)/);
  assert.match(failuresContent, /database connection refused/);
  assert.doesNotMatch(failuresContent, /\(unparsed\)/);
});

function writeFakeCheck(dir, name, { exitCode, output }) {
  const file = path.join(dir, name);
  fs.writeFileSync(
    file,
    ['#!/usr/bin/env bash', `echo "${output}"`, `exit ${exitCode}`, ''].join('\n')
  );
  fs.chmodSync(file, 0o755);
  return file;
}

test('failing typecheck exits 1, reports a Typecheck section, and skips the suite', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const fake = writeFakeCheck(dir, 'fake-tsc.sh', {
    exitCode: 2,
    output: "src/foo.ts(3,1): error TS2304: Cannot find name 'x'.",
  });
  fs.appendFileSync(path.join(dir, 'scratch', 'stack.md'), `- Typecheck: ${fake}\n`);
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /## Typecheck failed/);
  assert.match(failuresContent, /error TS2304/);
  assert.match(failuresContent, /Test suite not run/);
  const statusRow = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-test.md'), 'utf8');
  assert.match(statusRow, /\| test \| #<RUN> \|.*\| fail \|/);
});

test('failing lint with a green suite exits 1 and reports a Lint section', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const fake = writeFakeCheck(dir, 'fake-eslint.sh', {
    exitCode: 1,
    output: 'src/foo.ts:12:3 error no-restricted-syntax',
  });
  fs.appendFileSync(path.join(dir, 'scratch', 'stack.md'), `- Lint: ${fake}\n`);
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /## Lint failed/);
  assert.match(failuresContent, /no-restricted-syntax/);
});

test('passing typecheck and lint keep a green suite at exit 0 with header-only report', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const tsc = writeFakeCheck(dir, 'fake-tsc.sh', { exitCode: 0, output: 'ok' });
  const lint = writeFakeCheck(dir, 'fake-eslint.sh', { exitCode: 0, output: 'ok' });
  fs.appendFileSync(
    path.join(dir, 'scratch', 'stack.md'),
    `- Typecheck: ${tsc}\n- Lint: ${lint}\n`
  );
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.equal(failuresContent.trim(), '# Test Failures');
});

test('typecheck and lint run concurrently, not serially', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const slow = (name) => {
    const file = path.join(dir, name);
    fs.writeFileSync(file, ['#!/usr/bin/env bash', 'sleep 1', 'exit 0', ''].join('\n'));
    fs.chmodSync(file, 0o755);
    return file;
  };
  const tsc = slow('slow-tsc.sh');
  const lint = slow('slow-eslint.sh');
  fs.appendFileSync(
    path.join(dir, 'scratch', 'stack.md'),
    `- Typecheck: ${tsc}\n- Lint: ${lint}\n`
  );
  const start = Date.now();
  const res = run(dir, ['scratch']);
  const elapsed = Date.now() - start;
  assert.equal(res.status, 0, res.stderr);
  assert.ok(elapsed < 1800, `two 1s checks took ${elapsed}ms — expected concurrent (<1800ms), not serial (~2000ms)`);
});

test('lint script from package.json is auto-detected when no command is configured', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const fake = writeFakeCheck(dir, 'fake-eslint.sh', {
    exitCode: 1,
    output: 'src/foo.ts:1:1 error detected-via-package-json',
  });
  fs.writeFileSync(
    path.join(dir, 'package.json'),
    JSON.stringify({ name: 'fixture', scripts: { lint: fake } })
  );
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /## Lint failed/);
  assert.match(failuresContent, /detected-via-package-json/);
});

test('resolves Typecheck/Lint using the exact key names ship:init writes to ship/config.md', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  const tsc = writeFakeCheck(dir, 'fake-tsc.sh', {
    exitCode: 2,
    output: "src/foo.ts(3,1): error TS2304: Cannot find name 'x'.",
  });
  // Same key spelling as the "## Stack" template in src/skills/init/SKILL.md
  // ("Typecheck", not "Typecheck command") — a prior key mismatch meant this
  // config value was silently never read.
  fs.writeFileSync(path.join(dir, 'ship', 'config.md'), `# Config\n\n- Typecheck: ${tsc}\n`);
  const res = run(dir, ['scratch', '--config', 'ship/config.md']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /## Typecheck failed/);
  assert.match(failuresContent, /error TS2304/);
});

test('"Typecheck: none" / "Lint: none" is treated as not configured, never executed as a literal command', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  fs.appendFileSync(path.join(dir, 'scratch', 'stack.md'), '- Typecheck: none\n- Lint: none\n');
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.equal(failuresContent.trim(), '# Test Failures');
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
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), `# Stack\n\n- Test Framework: ${fakePytest}\n`);
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 1);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.match(failuresContent, /test_math\.py \(2 failures\)/);
});

test('--static-only: failing typecheck exits 1, writes static-failures.md and a fail static row, needs no test runner', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'test-exec-'));
  fs.mkdirSync(path.join(dir, 'scratch'));
  fs.mkdirSync(path.join(dir, 'ship'));
  fs.writeFileSync(path.join(dir, 'ship', 'config.md'), '# Config\n');
  const fake = writeFakeCheck(dir, 'fake-tsc.sh', {
    exitCode: 2,
    output: "src/foo.ts(3,1): error TS2304: Cannot find name 'x'.",
  });
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), `# Stack\n\n- Typecheck: ${fake}\n`);
  const res = run(dir, ['scratch', '--static-only']);
  assert.equal(res.status, 1);
  const content = fs.readFileSync(path.join(dir, 'scratch', 'static-failures.md'), 'utf8');
  assert.match(content, /## Typecheck failed/);
  assert.match(content, /error TS2304/);
  const statusRow = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-static.md'), 'utf8');
  assert.match(statusRow, /\| static \| #<RUN> \|.*\| fail \|/);
});

test('--static-only: failing lint exits 1 and reports a Lint section', () => {
  const dir = setupProject({});
  const fake = writeFakeCheck(dir, 'fake-eslint.sh', {
    exitCode: 1,
    output: 'src/foo.ts:12:3 error no-restricted-syntax',
  });
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), `# Stack\n\n- Lint: ${fake}\n`);
  const res = run(dir, ['scratch', '--static-only']);
  assert.equal(res.status, 1);
  const content = fs.readFileSync(path.join(dir, 'scratch', 'static-failures.md'), 'utf8');
  assert.match(content, /## Lint failed/);
  assert.match(content, /no-restricted-syntax/);
});

test('--static-only: passing typecheck+lint exits 0 with a header-only report and a pass static row', () => {
  const dir = setupProject({});
  const tsc = writeFakeCheck(dir, 'fake-tsc.sh', { exitCode: 0, output: 'ok' });
  const lint = writeFakeCheck(dir, 'fake-eslint.sh', { exitCode: 0, output: 'ok' });
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), `# Stack\n\n- Typecheck: ${tsc}\n- Lint: ${lint}\n`);
  const res = run(dir, ['scratch', '--static-only']);
  assert.equal(res.status, 0, res.stderr);
  const content = fs.readFileSync(path.join(dir, 'scratch', 'static-failures.md'), 'utf8');
  assert.equal(content.trim(), '# Static Failures');
  const statusRow = fs.readFileSync(path.join(dir, 'scratch', 'phase-status-static.md'), 'utf8');
  assert.match(statusRow, /\| static \| #<RUN> \|.*\| pass \|/);
});

test('--static-only: neither typecheck nor lint resolves exits 2 (skip) and writes no report', () => {
  const dir = setupProject({});
  fs.writeFileSync(path.join(dir, 'scratch', 'stack.md'), '# Stack\n\n- Typecheck: none\n- Lint: none\n');
  const res = run(dir, ['scratch', '--static-only']);
  assert.equal(res.status, 2);
  assert.ok(!fs.existsSync(path.join(dir, 'scratch', 'static-failures.md')));
});

test('suite path does NOT re-run typecheck when static-exec-done.txt already exists', () => {
  const dir = setupProject({
    testRunner: 'node --test',
    packageManager: 'npm',
    testFileContent: PASSING_TEST,
  });
  // A typecheck that would fail if run — but the static gate already ran, so the
  // suite must skip it and stay green.
  const fake = writeFakeCheck(dir, 'fake-tsc.sh', {
    exitCode: 2,
    output: "src/foo.ts(3,1): error TS2304: Cannot find name 'x'.",
  });
  fs.appendFileSync(path.join(dir, 'scratch', 'stack.md'), `- Typecheck: ${fake}\n`);
  fs.writeFileSync(path.join(dir, 'scratch', 'static-exec-done.txt'), '');
  const res = run(dir, ['scratch']);
  assert.equal(res.status, 0, res.stderr);
  const failuresContent = fs.readFileSync(path.join(dir, 'scratch', 'test-failures.md'), 'utf8');
  assert.doesNotMatch(failuresContent, /## Typecheck failed/);
});
