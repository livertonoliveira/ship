'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const CAPTURE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'capture-diff.sh');
const VALID = 'diff --git a/x b/x\n@@ -1 +1 @@\n+hi\n';

function tmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'capture-diff-'));
}

test('--prefer reuses a non-empty valid unified diff', () => {
  const dir = tmp();
  const existing = path.join(dir, 'existing.md');
  const out = path.join(dir, 'out.md');
  fs.writeFileSync(existing, VALID);
  const res = spawnSync('bash', [CAPTURE, out, '--prefer', existing], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(fs.readFileSync(out, 'utf8'), VALID);
});

test('--prefer with same path as output is a no-op that preserves the file', () => {
  const dir = tmp();
  const existing = path.join(dir, 'diff.md');
  fs.writeFileSync(existing, VALID);
  const res = spawnSync('bash', [CAPTURE, existing, '--prefer', existing], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  assert.equal(fs.readFileSync(existing, 'utf8'), VALID);
});

test('--prefer ignores an empty preferred file and falls back to capture', () => {
  const dir = tmp();
  const empty = path.join(dir, 'empty.md');
  const out = path.join(dir, 'out.md');
  fs.writeFileSync(empty, '');
  // Capture runs git against the real repo; it must not crash and must produce a file.
  const res = spawnSync('bash', [CAPTURE, out, '--prefer', empty], {
    cwd: process.cwd(),
    encoding: 'utf8',
  });
  assert.equal(res.status, 0, res.stderr);
  assert.ok(fs.existsSync(out));
});

test('--prefer ignores a non-diff preferred file and falls back to capture', () => {
  const dir = tmp();
  const bogus = path.join(dir, 'bogus.md');
  const out = path.join(dir, 'out.md');
  fs.writeFileSync(bogus, 'this is not a diff\n');
  const res = spawnSync('bash', [CAPTURE, out, '--prefer', bogus], {
    cwd: process.cwd(),
    encoding: 'utf8',
  });
  assert.equal(res.status, 0, res.stderr);
  assert.notEqual(fs.readFileSync(out, 'utf8'), 'this is not a diff\n');
});
