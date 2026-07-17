'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HOOK = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'run-init.sh');

function sh(cwd, cmd, args) {
  return spawnSync(cmd, args, { cwd, encoding: 'utf8' });
}

function setupRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-init-'));
  sh(dir, 'git', ['init', '-q', '-b', 'main']);
  sh(dir, 'git', ['config', 'user.email', 'test@example.com']);
  sh(dir, 'git', ['config', 'user.name', 'Test']);
  fs.mkdirSync(path.join(dir, 'ship'));
  fs.writeFileSync(
    path.join(dir, 'ship', 'config.md'),
    '# Config\n\n- Language: TypeScript\n- Runtime: Node 20\n- Framework: none\n- Test runner: vitest\n- Package manager: npm\n'
  );
  fs.writeFileSync(path.join(dir, '.gitignore'), '.context/\n');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'hello\n');
  sh(dir, 'git', ['add', '-A']);
  sh(dir, 'git', ['commit', '-q', '-m', 'init']);
  sh(dir, 'git', ['update-ref', 'refs/remotes/origin/main', 'HEAD']);
  return dir;
}

function runInit(dir, args) {
  return sh(dir, 'bash', [HOOK, ...args]);
}

test('fresh init creates every canonical scratch file and classifies the diff', () => {
  const dir = setupRepo();
  const res = runInit(dir, ['TASK-A']);
  assert.equal(res.status, 0, res.stderr);
  const scratch = path.join(dir, '.context', 'ship-run', 'TASK-A');
  for (const f of [
    'stack.md',
    'diff.md',
    'diff-class.txt',
    'phase-status.md',
    'dispatch-log.md',
    'pre-quality-snapshot.sha',
    'pre-develop-files.txt',
  ]) {
    assert.ok(fs.existsSync(path.join(scratch, f)), `${f} missing`);
  }
  assert.match(fs.readFileSync(path.join(scratch, 'stack.md'), 'utf8'), /- Language: TypeScript/);
  assert.match(res.stdout, /INIT fresh/);
  assert.match(res.stdout, /diff_class=trivial/);
});

test('check mode reports RESUME (exit 3) when dispatch rows exist', () => {
  const dir = setupRepo();
  assert.equal(runInit(dir, ['TASK-A']).status, 0);
  const scratch = path.join(dir, '.context', 'ship-run', 'TASK-A');
  fs.appendFileSync(
    path.join(scratch, 'dispatch-log.md'),
    '| dev | Skill | ship:develop | sonnet | 2026-07-17T10:00:00Z |\n'
  );
  fs.appendFileSync(
    path.join(scratch, 'phase-status.md'),
    '| plan | #1 | 2026-07-17T09:59:00Z | 2 | pass | 0 | 0 | 0 | 0 | |\n'
  );
  const res = runInit(dir, ['TASK-A']);
  assert.equal(res.status, 3);
  assert.match(res.stdout, /RESUME/);
  assert.match(res.stdout, /dispatched=dev/);
  assert.match(res.stdout, /completed=plan/);
  assert.match(res.stdout, /unfinished=dev/);
});

test('resume mode preserves existing state and only refreshes the diff', () => {
  const dir = setupRepo();
  assert.equal(runInit(dir, ['TASK-A']).status, 0);
  const scratch = path.join(dir, '.context', 'ship-run', 'TASK-A');
  const marker = '| dev | Skill | ship:develop | sonnet | 2026-07-17T10:00:00Z |\n';
  fs.appendFileSync(path.join(scratch, 'dispatch-log.md'), marker);
  fs.writeFileSync(path.join(dir, 'b.txt'), 'new file\n');
  const res = runInit(dir, ['TASK-A', '--mode', 'resume']);
  assert.equal(res.status, 0, res.stderr);
  assert.ok(fs.readFileSync(path.join(scratch, 'dispatch-log.md'), 'utf8').includes(marker));
  assert.ok(fs.readFileSync(path.join(scratch, 'diff.md'), 'utf8').includes('b.txt'));
});

test('rejects task ids with characters outside [a-zA-Z0-9_-]', () => {
  const dir = setupRepo();
  const res = runInit(dir, ['../evil']);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /invalid task id/);
});
