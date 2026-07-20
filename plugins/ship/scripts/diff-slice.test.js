'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SLICE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'diff-slice.sh');

function block(pathName) {
  return (
    `diff --git a/${pathName} b/${pathName}\n` +
    `index 111..222 100644\n--- a/${pathName}\n+++ b/${pathName}\n@@ -1,1 +1,2 @@\n+x\n`
  );
}

function slice(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'diff-slice-'));
  fs.writeFileSync(path.join(dir, 'diff.md'), files.map(block).join(''));
  const res = spawnSync('bash', [SLICE, path.join(dir, 'diff.md'), '--out-dir', path.join(dir, 'out')], {
    encoding: 'utf8',
  });
  assert.equal(res.status, 0, res.stderr);
  const read = (name) => fs.readFileSync(path.join(dir, 'out', name), 'utf8');
  const filesIn = (name) =>
    read(name)
      .split('\n')
      .filter((l) => l.startsWith('diff --git '))
      .map((l) => l.replace(/^diff --git a\/(\S+).*/, '$1'));
  return {
    injection: filesIn('slice-injection.md'),
    auth: filesIn('slice-auth.md'),
    data: filesIn('slice-data.md'),
  };
}

test('routes a controller to injection only', () => {
  const s = slice(['src/users/users.controller.ts']);
  assert.deepEqual(s.injection, ['src/users/users.controller.ts']);
  assert.deepEqual(s.auth, []);
  assert.deepEqual(s.data, []);
});

test('routes a guard to auth only', () => {
  const s = slice(['src/auth/roles.guard.ts']);
  assert.deepEqual(s.auth, ['src/auth/roles.guard.ts']);
  assert.deepEqual(s.injection, []);
});

test('routes a secret/config file to data only', () => {
  const s = slice(['src/config/secret.config.ts']);
  assert.deepEqual(s.data, ['src/config/secret.config.ts']);
  assert.deepEqual(s.injection, []);
});

test('a file matching multiple categories lands in each', () => {
  const s = slice(['src/auth/auth.controller.ts']);
  assert.ok(s.injection.includes('src/auth/auth.controller.ts'));
  assert.ok(s.auth.includes('src/auth/auth.controller.ts'));
});

test('an unmatched file is copied into all three slices', () => {
  const s = slice(['src/util/math.ts']);
  assert.deepEqual(s.injection, ['src/util/math.ts']);
  assert.deepEqual(s.auth, ['src/util/math.ts']);
  assert.deepEqual(s.data, ['src/util/math.ts']);
});

test('preserves full hunk bodies in the slice, not just the header', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'diff-slice-'));
  fs.writeFileSync(path.join(dir, 'diff.md'), block('src/users/users.controller.ts'));
  spawnSync('bash', [SLICE, path.join(dir, 'diff.md'), '--out-dir', path.join(dir, 'out')]);
  const out = fs.readFileSync(path.join(dir, 'out', 'slice-injection.md'), 'utf8');
  assert.match(out, /@@ -1,1 \+1,2 @@/);
  assert.match(out, /\+x/);
});

test('missing diff file fails fast', () => {
  const res = spawnSync('bash', [SLICE, '/nonexistent/diff.md', '--out-dir', '/tmp/x'], { encoding: 'utf8' });
  assert.equal(res.status, 1);
  assert.match(res.stderr, /diff file not found/);
});
