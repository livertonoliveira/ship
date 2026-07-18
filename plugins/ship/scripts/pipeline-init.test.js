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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pipeline-init-'));
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

function runPipelineInit(dir, args) {
  return sh(dir, 'bash', [PIPELINE, 'init', ...args]);
}

test('pipeline.sh init fresh creates every canonical scratch file and exits 0', () => {
  const dir = setupRepo();
  const res = runPipelineInit(dir, ['TASK-A']);
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
  assert.match(res.stdout, /INIT fresh/);
});

test('pipeline.sh init reports RESUME with exit 3 when dispatch rows exist', () => {
  const dir = setupRepo();
  assert.equal(runPipelineInit(dir, ['TASK-A']).status, 0);
  const scratch = path.join(dir, '.context', 'ship-run', 'TASK-A');
  fs.appendFileSync(
    path.join(scratch, 'dispatch-log.md'),
    '| dev | Skill | ship:develop | sonnet | 2026-07-17T10:00:00Z |\n'
  );
  fs.appendFileSync(
    path.join(scratch, 'phase-status.md'),
    '| plan | #1 | 2026-07-17T09:59:00Z | 2 | pass | 0 | 0 | 0 | 0 | |\n'
  );
  const res = runPipelineInit(dir, ['TASK-A']);
  assert.equal(res.status, 3);
  assert.match(res.stdout, /RESUME/);
  assert.match(res.stdout, /last_dispatch=/);
  assert.match(res.stdout, /dispatched=dev/);
  assert.match(res.stdout, /completed=plan/);
  assert.match(res.stdout, /unfinished=dev/);
});

test('pipeline.sh init rejects a task id with an invalid character', () => {
  const dir = setupRepo();
  const res = runPipelineInit(dir, ['../evil']);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /invalid task id/);
});

test('pipeline.sh init rejects a nonexistent config path', () => {
  const dir = setupRepo();
  const res = runPipelineInit(dir, ['TASK-A', '--config', 'does/not/exist.md']);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /config not found/);
});

test('pipeline.sh rejects an unknown subcommand', () => {
  const dir = setupRepo();
  const res = sh(dir, 'bash', [PIPELINE, 'bogus']);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /usage: pipeline\.sh/);
});

test('pipeline.sh with no subcommand exits 1 with usage', () => {
  const dir = setupRepo();
  const res = sh(dir, 'bash', [PIPELINE]);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /usage: pipeline\.sh/);
});

test('pipeline.sh init matches run-init.sh output byte-for-byte for the same inputs', () => {
  const dirA = setupRepo();
  const dirB = setupRepo();
  const runInit = path.join(__dirname, '..', '..', '..', 'src', 'hooks', 'run-init.sh');
  const resPipeline = runPipelineInit(dirA, ['TASK-A']);
  const resDirect = sh(dirB, 'bash', [runInit, 'TASK-A']);
  assert.equal(resPipeline.status, resDirect.status);
  assert.equal(
    resPipeline.stdout.replace(/TASK-A/g, 'X'),
    resDirect.stdout.replace(/TASK-A/g, 'X')
  );
});
