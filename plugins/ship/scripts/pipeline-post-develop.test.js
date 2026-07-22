'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PIPELINE = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'pipeline.sh');

function sh(cwd, cmd, args) {
  return spawnSync(cmd, args, { cwd, encoding: 'utf8' });
}

function setupRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'post-develop-'));
  sh(dir, 'git', ['init', '-q', '-b', 'main']);
  sh(dir, 'git', ['config', 'user.email', 'test@example.com']);
  sh(dir, 'git', ['config', 'user.name', 'Test']);
  fs.mkdirSync(path.join(dir, 'ship'));
  fs.writeFileSync(
    path.join(dir, 'ship', 'config.md'),
    '# Config\n\n- Runtime: Node 20\n- Framework: none\n- Package Manager: npm\n- Test Framework: vitest\n- Typecheck: tsc --noEmit\n- Lint: eslint .\n'
  );
  fs.writeFileSync(path.join(dir, '.gitignore'), '.context/\n');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello\n');
  sh(dir, 'git', ['add', '-A']);
  sh(dir, 'git', ['commit', '-q', '-m', 'init']);
  sh(dir, 'git', ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
  return dir;
}

function scratchOf(dir) {
  return path.join(dir, '.context', 'ship-run', 'TASK-A');
}

function parse(stdout) {
  const out = {};
  for (const line of stdout.trim().split('\n')) {
    const [k, v] = line.split('=');
    out[k] = v;
  }
  return out;
}

test('post-develop reports evidence=ok and a class when develop mutated the tree', () => {
  const dir = setupRepo();
  assert.equal(sh(dir, 'bash', [PIPELINE, 'init', 'TASK-A']).status, 0);
  // Simulate develop writing new source into the working tree (uncommitted).
  fs.writeFileSync(path.join(dir, 'src.js'), 'export const f = () => 1;\n');
  const res = sh(dir, 'bash', [PIPELINE, 'post-develop', scratchOf(dir)]);
  assert.equal(res.status, 0, res.stderr);
  const out = parse(res.stdout);
  assert.equal(out.evidence, 'ok');
  assert.match(out.diff_class, /^(trivial|minor|normal|large)\b/, res.stdout);
  const touched = fs.readFileSync(path.join(scratchOf(dir), 'develop-touched-files.txt'), 'utf8');
  assert.match(touched, /src\.js/);
});

test('post-develop reports evidence=fail when nothing was written and the diff is empty', () => {
  const dir = setupRepo();
  assert.equal(sh(dir, 'bash', [PIPELINE, 'init', 'TASK-A']).status, 0);
  // No develop mutation at all.
  const res = sh(dir, 'bash', [PIPELINE, 'post-develop', scratchOf(dir)]);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(parse(res.stdout).evidence, 'fail');
});

test('post-develop counts untested touched source files', () => {
  const dir = setupRepo();
  assert.equal(sh(dir, 'bash', [PIPELINE, 'init', 'TASK-A']).status, 0);
  fs.writeFileSync(path.join(dir, 'lonely.js'), 'export const g = () => 2;\n');
  const res = sh(dir, 'bash', [PIPELINE, 'post-develop', scratchOf(dir)]);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(parse(res.stdout).untested, '1');
});

test('post-develop fails cleanly without a pre-develop snapshot', () => {
  const dir = setupRepo();
  fs.mkdirSync(scratchOf(dir), { recursive: true });
  const res = sh(dir, 'bash', [PIPELINE, 'post-develop', scratchOf(dir)]);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /pre-develop snapshot not found/);
});
